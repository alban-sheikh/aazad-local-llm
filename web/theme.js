// Runs in <head> so the page never flashes the wrong theme.
(function () {
  let theme = 'auto';
  try { theme = JSON.parse(localStorage.getItem('aazad.theme')) || 'auto'; } catch (e) { /* no storage */ }
  const dark = theme === 'dark' || (theme === 'auto' && matchMedia('(prefers-color-scheme: dark)').matches);
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
})();
