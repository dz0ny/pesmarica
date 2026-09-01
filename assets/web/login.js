const form = document.getElementById('login');
const error = document.getElementById('error');

form.addEventListener('submit', async (event) => {
  event.preventDefault();
  error.hidden = true;
  const response = await fetch('/api/login', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ password: document.getElementById('password').value }),
  });
  if (response.ok) {
    // The server set the cookie; go wherever the operator was headed.
    location.href = new URLSearchParams(location.search).get('next') || '/';
    return;
  }
  error.hidden = false;
  form.password.select();
});
