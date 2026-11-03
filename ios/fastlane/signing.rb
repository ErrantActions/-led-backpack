require "base64"
require "fileutils"
require "json"
require "open3"
require "openssl"
require "securerandom"
require "time"

ROOT = File.join(ENV.fetch("RUNNER_TEMP"), "led-backpack-signing")
STATE = File.join(ROOT, "cleanup.json")
BUNDLE = "com.errantactions.ledbackpack"

def command(label, *args)
  output, error, status = Open3.capture3(*args)
  unless status.success?
    detail = case error
    when /MAC verification failed|invalid password|incorrect password/i
      "macOS could not decrypt the PKCS12 identity; check its export password and encoding."
    when /unknown format|unsupported format|unsupported algorithm/i
      "macOS rejected the signing asset format."
    when /user interaction.*not allowed|interaction is not allowed/i
      "macOS denied noninteractive keychain access."
    else
      code = error[/\bOSStatus\s*[:=]?\s*(-?\d+)/i, 1]
      code ? "macOS reported OSStatus #{code}." : "Check the configured signing assets."
    end
    abort "#{label} failed (exit #{status.exitstatus}). #{detail}"
  end
  output.strip
end

def env(name, value)
  abort "Invalid newline in generated #{name}." if value.include?("\n") || value.include?("\r")
  File.open(ENV.fetch("GITHUB_ENV"), "a") { |file| file.puts "#{name}=#{value}" }
end

def save_state(value)
  File.write(STATE, JSON.generate(value), mode: "w", perm: 0o600)
end

def decode_secret(name, filename)
  data = Base64.strict_decode64(ENV.fetch(name))
  abort "Empty signing asset: #{name}." if data.empty?
  path = File.join(ROOT, filename)
  File.write(path, data, mode: "wb", perm: 0o600)
  path
rescue ArgumentError
  abort "#{name} must be a single-line base64 value."
end

if ARGV.first == "cleanup"
  failures = []
  if File.exist?(STATE)
    state = JSON.parse(File.read(STATE))
    _, _, restored = Open3.capture3("security", "list-keychains", "-d", "user", "-s", *state.fetch("search"))
    failures << "Restore keychain search list failed (exit #{restored.exitstatus})." unless restored.success?
    if state["keychain_created"]
      _, _, deleted = Open3.capture3("security", "delete-keychain", state.fetch("keychain"))
      failures << "Delete temporary signing keychain failed (exit #{deleted.exitstatus})." unless deleted.success?
    end
    if state["profile"] && File.exist?(state["profile"])
      begin
        File.delete(state["profile"])
      rescue SystemCallError => error
        failures << "Profile cleanup failed (#{error.class})."
      end
    end
  end
  begin
    FileUtils.remove_entry_secure(ROOT) if File.directory?(ROOT)
  rescue SystemCallError => error
    failures << "Temporary-file cleanup failed (#{error.class})."
  end
  abort failures.join(" ") unless failures.empty?
  puts "Temporary signing assets removed."
  exit
end

required = %w[APPLE_TEAM_ID IOS_DISTRIBUTION_P12_BASE64 IOS_DISTRIBUTION_P12_PASSWORD IOS_APPSTORE_PROFILE_BASE64
  APP_STORE_CONNECT_KEY_ID APP_STORE_CONNECT_ISSUER_ID APP_STORE_CONNECT_PRIVATE_KEY_BASE64]
missing = required.select { |name| ENV[name].to_s.empty? }
abort "Missing signing secrets: #{missing.join(', ')}" unless missing.empty?
begin
  OpenSSL::PKey.read(Base64.strict_decode64(ENV.fetch("APP_STORE_CONNECT_PRIVATE_KEY_BASE64")))
rescue ArgumentError, OpenSSL::PKey::PKeyError
  abort "App Store Connect private key must be a valid one-line base64-encoded P8 key."
end
team = ENV.fetch("APPLE_TEAM_ID")
abort "APPLE_TEAM_ID must be Apple's ten-character Team ID." unless team.match?(/\A[A-Z0-9]{10}\z/)
FileUtils.mkdir_p(ROOT, mode: 0o700)
keychain = File.join(ROOT, "signing.keychain-db")
search = command("Read keychain search list", "security", "list-keychains", "-d", "user")
  .lines.map { |line| line.strip.delete_prefix('"').delete_suffix('"') }.reject(&:empty?)
state = { "search" => search, "keychain" => keychain }
save_state(state)
p12 = decode_secret("IOS_DISTRIBUTION_P12_BASE64", "distribution.p12")
profile = decode_secret("IOS_APPSTORE_PROFILE_BASE64", "profile.mobileprovision")
plist = File.join(ROOT, "profile.plist")
File.write(plist, command("Decode provisioning profile", "security", "cms", "-D", "-i", profile), mode: "w", perm: 0o600)
read = ->(key) { command("Read profile #{key}", "/usr/libexec/PlistBuddy", "-c", "Print :#{key}", plist) }
prefix = read.call("ApplicationIdentifierPrefix:0")
abort "Provisioning profile belongs to a different team or bundle ID." unless read.call("TeamIdentifier:0") == team &&
  read.call("Entitlements:application-identifier") == "#{prefix}.#{BUNDLE}"
abort "Provisioning profile is expired." unless Time.parse(read.call("ExpirationDate")) > Time.now
abort "Use an App Store distribution profile, not a development profile." unless read.call("Entitlements:get-task-allow") == "false"
_, _, devices_status = Open3.capture3("/usr/libexec/PlistBuddy", "-c", "Print :ProvisionedDevices", plist)
abort "Use an App Store profile, not an Ad Hoc profile with device IDs." if devices_status.success?
_, _, all_devices_status = Open3.capture3("/usr/libexec/PlistBuddy", "-c", "Print :ProvisionsAllDevices", plist)
abort "Enterprise profiles cannot be used for App Store TestFlight." if all_devices_status.success?
uuid = read.call("UUID")
abort "Invalid profile UUID." unless uuid.match?(/\A[0-9A-Fa-f-]{36}\z/)
destination = File.expand_path("~/Library/MobileDevice/Provisioning Profiles/#{uuid}.mobileprovision")
abort "Refusing to overwrite an existing profile in this runner." if File.exist?(destination)
FileUtils.mkdir_p(File.dirname(destination))
FileUtils.cp(profile, destination)
state["profile"] = destination
save_state(state)
password = SecureRandom.hex(32)
command("Create temporary keychain", "security", "create-keychain", "-p", password, keychain)
state["keychain_created"] = true
save_state(state)
command("Configure signing keychain", "security", "set-keychain-settings", "-lut", "3600", keychain)
command("Unlock signing keychain", "security", "unlock-keychain", "-p", password, keychain)
command("Import Apple Distribution identity", "security", "import", p12, "-k", keychain,
  "-P", ENV.fetch("IOS_DISTRIBUTION_P12_PASSWORD"), "-t", "cert", "-f", "pkcs12",
  "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
command("Authorize codesign", "security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, keychain)
command("Set signing keychain search list", "security", "list-keychains", "-d", "user", "-s", keychain, *search)
identities = command("Find signing identity", "security", "find-identity", "-v", "-p", "codesigning", keychain)
hashes = identities.scan(/\b([0-9A-F]{40})\b/).flatten
abort "The P12 must contain exactly one valid Apple Distribution signing identity." unless hashes.length == 1 && identities.include?("Apple Distribution")
env("SIGNING_KEYCHAIN", keychain)
env("SIGNING_CERT_SHA1", hashes.first)
env("PROFILE_UUID", uuid)
puts "Distribution identity and App Store profile installed. Secret values are not printed."
