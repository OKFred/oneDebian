'use strict';
(async () => {
  const token = new URLSearchParams(location.hash.slice(1)).get('token');
  history.replaceState(null, '', '/');
  const message = document.getElementById('message');
  try {
    if (token) {
      const response = await fetch('/auth', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        credentials: 'same-origin', body: JSON.stringify({token})
      });
      if (!response.ok) throw new Error('授权无效，请重新从 oneDebian 菜单打开桌面。');
    }
    const check = await fetch('/vnc.html', {credentials: 'same-origin'});
    if (!check.ok) throw new Error('请从 oneDebian 菜单打开桌面，以获取本地访问授权。');
    location.replace('/vnc.html?autoconnect=1&shared=1&resize=scale&view_only=1');
  } catch (error) {
    message.textContent = error.message;
  }
})();
