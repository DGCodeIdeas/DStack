<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="csrf-token" content="{{ csrf_token() }}">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DStack - Login</title>
    <link rel="stylesheet" href="/assets/css/app.css">
    <style>
        body {
            display: flex;
            align-items: center;
            justify-content: center;
            min-height: 100vh;
            margin: 0;
            background: radial-gradient(ellipse at top left, #1f2937 0%, #0b0f19 70%);
            color: #f3f4f6;
            font-family: system-ui, -apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, Helvetica, Arial, sans-serif;
        }
        .login-card {
            background: rgba(17, 24, 39, 0.85);
            border: 1px solid #374151;
            border-radius: 12px;
            padding: 32px;
            width: min(400px, 92vw);
            backdrop-filter: blur(6px);
        }
        .login-header {
            text-align: center;
            margin-bottom: 24px;
        }
        .login-header h1 {
            margin: 0;
            font-size: 24px;
            letter-spacing: 0.3px;
        }
        .login-header p {
            margin: 8px 0 0;
            color: #9ca3af;
            font-size: 14px;
        }
        .form-group {
            margin-bottom: 16px;
        }
        label {
            display: block;
            font-size: 14px;
            color: #9ca3af;
            margin-bottom: 6px;
        }
        input[type="email"], input[type="password"] {
            width: 100%;
            background: #1f2937;
            border: 1px solid #374151;
            border-radius: 8px;
            color: #f3f4f6;
            padding: 10px 12px;
            font-size: 14px;
        }
        input:focus {
            outline: none;
            border-color: #f59e0b;
            box-shadow: 0 0 0 3px rgba(245, 158, 11, 0.2);
        }
        .btn {
            width: 100%;
            background: #2563eb;
            border: 1px solid #2563eb;
            border-radius: 8px;
            color: #f3f4f6;
            padding: 10px;
            font-size: 14px;
            font-weight: 600;
            cursor: pointer;
            margin-top: 8px;
        }
        .btn:hover {
            background: #1d4ed8;
        }
        .btn:disabled {
            opacity: 0.6;
            cursor: not-allowed;
        }
        .error {
            color: #fecaca;
            font-size: 13px;
            margin-top: 12px;
            padding: 10px;
            background: rgba(127, 29, 29, 0.2);
            border: 1px solid #7f1d1d;
            border-radius: 8px;
            display: none;
        }
        .error.visible {
            display: block;
        }
    </style>
</head>
<body>
    <div class="login-card">
        <div class="login-header">
            <h1>DStack</h1>
            <p>Local Development Stack</p>
        </div>
        <form id="login-form">
            <div class="form-group">
                <label for="email">Email</label>
                <input type="email" id="email" name="email" required autofocus>
            </div>
            <div class="form-group">
                <label for="password">Password</label>
                <input type="password" id="password" name="password" required>
            </div>
            <button type="submit" class="btn" id="login-btn">Sign In</button>
        </form>
        <div id="login-error" class="error"></div>
    </div>

    <script>
        const form = document.getElementById('login-form');
        const btn = document.getElementById('login-btn');
        const error = document.getElementById('login-error');

        form.addEventListener('submit', async (e) => {
            e.preventDefault();
            error.classList.remove('visible');
            btn.disabled = true;
            btn.textContent = 'Signing in...';

            try {
                const res = await fetch('/login', {
                    method: 'POST',
                    headers: {
                        'Content-Type': 'application/json',
                        'X-CSRF-TOKEN': document.querySelector('meta[name="csrf-token"]')?.content || ''
                    },
                    body: JSON.stringify({
                        email: document.getElementById('email').value,
                        password: document.getElementById('password').value,
                    })
                });
                const data = await res.json();
                if (data.redirect) {
                    location.href = data.redirect;
                } else if (!res.ok) {
                    error.textContent = data.message || 'Login failed.';
                    error.classList.add('visible');
                }
            } catch (err) {
                error.textContent = 'Network error.';
                error.classList.add('visible');
            } finally {
                btn.disabled = false;
                btn.textContent = 'Sign In';
            }
        });
    </script>
</body>
</html>
