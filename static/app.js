document.querySelectorAll('[data-auto-submit]').forEach(select => select.addEventListener('change', () => select.form.submit()));
document.querySelectorAll('form[data-confirm]').forEach(form => form.addEventListener('submit', event => { if (!window.confirm(form.dataset.confirm)) {event.preventDefault();event.stopImmediatePropagation();} }));
document.querySelectorAll('[data-login]').forEach(button => button.addEventListener('click', () => {
  document.querySelector('#username').value = button.dataset.login;
  document.querySelector('#password').value = 'library-demo';
  document.querySelector('#password').focus();
}));
document.querySelectorAll('[data-copy]').forEach(button => button.addEventListener('click', async () => {
  try {
    await navigator.clipboard.writeText(document.getElementById(button.dataset.copy).textContent);
    button.textContent = 'Copied ✓';
  } catch (_) {
    button.textContent = 'Select the token above to copy';
  }
}));
document.querySelectorAll('form[method="post"]').forEach(form => form.addEventListener('submit', () => {
  const button = form.querySelector('button[type="submit"], button:not([type])');
  if (button) { button.disabled = true; }
}));
