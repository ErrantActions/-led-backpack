const phone = document.getElementById('theme-phone');
const display = phone.querySelector('.pixel-display');
const feedback = document.getElementById('prototype-feedback');
for (const button of phone.querySelectorAll('[data-color]')) {
  button.addEventListener('click', () => {
    display.style.setProperty('--ink', button.dataset.color);
    for (const swatch of phone.querySelectorAll('[data-color]')) {
      swatch.classList.toggle('selected', swatch === button);
      swatch.setAttribute('aria-pressed', String(swatch === button));
    }
    feedback.textContent = 'Mockup ink changed locally. Nothing sent to the backpack.';
  });
}
for (const button of phone.querySelectorAll('[data-font]')) {
  button.addEventListener('click', () => {
    display.classList.remove('font-mono', 'font-rounded', 'font-system');
    display.classList.add(`font-${button.dataset.font}`);
    for (const choice of phone.querySelectorAll('[data-font]')) choice.classList.toggle('selected', choice === button);
  });
}
document.getElementById('type-size').addEventListener('input', event => {
  display.style.setProperty('--number-scale', event.target.value);
  document.getElementById('type-output').textContent = `${Number(event.target.value).toFixed(2)}x`;
});
document.getElementById('mock-apply').addEventListener('click', () => {
  feedback.textContent = 'Design preview only. The native iOS app saves and applies real presets.';
});
document.getElementById('fold-preview').addEventListener('click', event => {
  const compact = document.querySelector('.duo-workspace').classList.toggle('is-compact');
  event.target.textContent = compact ? 'Preview expanded layout' : 'Preview compact layout';
});
