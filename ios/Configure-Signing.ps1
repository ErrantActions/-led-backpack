#requires -Version 5.1
param(
    [Parameter(Mandatory = $true)][string]$P12Path,
    [Parameter(Mandatory = $true)][string]$ProfilePath,
    [Parameter(Mandatory = $true)][string]$ApiKeyPath,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Z0-9]{10}$')][string]$TeamId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[A-Z0-9]+$')][string]$KeyId,
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-fA-F0-9]{8}(-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$')][string]$IssuerId
)

$ErrorActionPreference = 'Stop'
$repository = 'ErrantActions/-led-backpack'
$environment = 'testflight'
$bundleId = 'com.errantactions.ledbackpack'
$openssl = Join-Path $env:ProgramFiles 'Git\usr\bin\openssl.exe'
if (-not (Test-Path -LiteralPath $openssl -PathType Leaf)) { throw 'Install Git for Windows with OpenSSL first.' }
$command = Get-Command gh -ErrorAction SilentlyContinue
if ($command) { $gh = $command.Source }
else {
    $installation = Get-ChildItem (Join-Path $env:LOCALAPPDATA 'Programs') -Directory -Filter 'GitHubCLI-*' |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $installation) { throw 'Install and authenticate GitHub CLI first.' }
    $gh = Join-Path $installation.FullName 'bin\gh.exe'
}
foreach ($path in @($P12Path, $ProfilePath, $ApiKeyPath)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Required signing file not found: $path" }
}
$P12Path = (Resolve-Path -LiteralPath $P12Path).ProviderPath
$ApiKeyPath = (Resolve-Path -LiteralPath $ApiKeyPath).ProviderPath

function Invoke-PrivateCommand {
    param([string]$Executable, [string]$Arguments, [string]$Label,
        [string]$InputValue, [hashtable]$ChildEnvironment = @{})
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Executable
    $start.Arguments = $Arguments
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($entry in $ChildEnvironment.GetEnumerator()) { $start.EnvironmentVariables[$entry.Key] = $entry.Value }
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Could not start $Label." }
        $output = $process.StandardOutput.ReadToEndAsync()
        $errors = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Write($InputValue)
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(120000)) {
            $process.Kill()
            throw "$Label timed out."
        }
        $null = $errors.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "$Label failed (exit $($process.ExitCode)). No secret values were printed." }
        return $output.GetAwaiter().GetResult()
    } finally { $process.Dispose() }
}

$null = Invoke-PrivateCommand $gh 'auth status --hostname github.com' 'GitHub authentication'
$null = Invoke-PrivateCommand $gh "api repos/$repository/environments/$environment" 'Check the preconfigured testflight environment'
Add-Type -AssemblyName System.Security
$cms = New-Object Security.Cryptography.Pkcs.SignedCms
$cms.Decode([IO.File]::ReadAllBytes($ProfilePath))
$cms.CheckSignature($true)
$xml = New-Object Xml.XmlDocument
$xml.XmlResolver = $null
$xml.LoadXml([Text.Encoding]::UTF8.GetString($cms.ContentInfo.Content))
$dict = $xml.SelectSingleNode('/plist/dict')
function ValueNode($parent, $key) { $parent.SelectSingleNode("key[text()='$key']/following-sibling::*[1]") }
$entitlements = ValueNode $dict 'Entitlements'
if ((ValueNode $entitlements 'com.apple.developer.applesignin').InnerText -ne 'Default') {
    throw 'Regenerate the LED Backpack App Store profile with Sign in with Apple enabled.'
}
if ((ValueNode $dict 'TeamIdentifier').InnerText -ne $TeamId -or
    (ValueNode $entitlements 'application-identifier').InnerText -ne "$TeamId.$bundleId") {
    throw 'The profile belongs to a different app or Apple team.'
}
if ([DateTime]::Parse((ValueNode $dict 'ExpirationDate').InnerText).ToUniversalTime() -le [DateTime]::UtcNow) {
    throw 'The provisioning profile has expired.'
}
if ((ValueNode $entitlements 'get-task-allow').Name -ne 'false' -or
    (ValueNode $dict 'ProvisionedDevices') -or (ValueNode $dict 'ProvisionsAllDevices')) {
    throw 'Use an App Store Connect distribution profile, not Development, Ad Hoc or enterprise.'
}
$thumbprints = @((ValueNode $dict 'DeveloperCertificates').SelectNodes('data') | ForEach-Object {
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String($_.InnerText))
    try { $certificate.Thumbprint } finally { $certificate.Dispose() }
})
$null = Invoke-PrivateCommand $openssl "pkey -in `"$ApiKeyPath`" -check -noout" 'Validate the upload API key'
Write-Host "Destination: $repository, environment: $environment. No build or upload will be triggered."
$secure = Read-Host 'Enter the existing distribution P12 export password (never paste it into chat)' -AsSecureString
$password = $null
try {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    if ([string]::IsNullOrWhiteSpace($password)) { throw 'A P12 export password is required.' }
    $pem = Invoke-PrivateCommand $openssl "pkcs12 -in `"$P12Path`" -passin env:LED_BACKPACK_P12_PASSWORD -clcerts -nokeys" `
        'Validate the P12 password and certificate' -ChildEnvironment @{LED_BACKPACK_P12_PASSWORD = $password}
    $matches = [regex]::Matches($pem, '(?s)-----BEGIN CERTIFICATE-----(.*?)-----END CERTIFICATE-----')
    if ($matches.Count -ne 1) { throw 'The P12 must contain exactly one signing certificate.' }
    $certificate = New-Object Security.Cryptography.X509Certificates.X509Certificate2 -ArgumentList @(,[Convert]::FromBase64String($matches[0].Groups[1].Value))
    try {
        if ($thumbprints -notcontains $certificate.Thumbprint) { throw 'The P12 does not match the provisioning profile.' }
        if ($certificate.NotAfter.ToUniversalTime() -le [DateTime]::UtcNow) { throw 'The P12 certificate has expired.' }
    } finally { $certificate.Dispose() }
    $secrets = [ordered]@{
        APPLE_TEAM_ID = $TeamId
        IOS_DISTRIBUTION_P12_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($P12Path))
        IOS_DISTRIBUTION_P12_PASSWORD = $password
        IOS_APPSTORE_PROFILE_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ProfilePath))
        APP_STORE_CONNECT_KEY_ID = $KeyId
        APP_STORE_CONNECT_ISSUER_ID = $IssuerId
        APP_STORE_CONNECT_PRIVATE_KEY_BASE64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ApiKeyPath))
    }
    foreach ($entry in $secrets.GetEnumerator()) {
        $null = Invoke-PrivateCommand $gh "secret set $($entry.Key) --repo $repository --env $environment" `
            "Configure secret $($entry.Key)" -InputValue $entry.Value
        Write-Host "Configured secret: $($entry.Key)"
    }
    Write-Host 'Signing secrets configured. No build or TestFlight upload was triggered.'
} finally {
    $secure.Dispose()
    $password = $null
    if ($secrets) { $secrets.Clear() }
}
