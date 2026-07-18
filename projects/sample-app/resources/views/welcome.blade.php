<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ config('app.name') }}</title>
    <style>
        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            padding: 2rem;
        }
        .container {
            background: white;
            border-radius: 16px;
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            padding: 3rem;
            max-width: 600px;
            width: 100%;
        }
        h1 {
            color: #1a202c;
            font-size: 2.5rem;
            margin-bottom: 1rem;
            text-align: center;
        }
        .subtitle {
            color: #718096;
            text-align: center;
            margin-bottom: 2rem;
            font-size: 1.1rem;
        }
        .links {
            display: flex;
            flex-direction: column;
            gap: 1rem;
        }
        .link-card {
            display: flex;
            align-items: center;
            padding: 1rem 1.5rem;
            background: #f7fafc;
            border-radius: 8px;
            text-decoration: none;
            color: #2d3748;
            transition: all 0.2s;
            border: 1px solid #e2e8f0;
        }
        .link-card:hover {
            background: #edf2f7;
            transform: translateX(4px);
            border-color: #cbd5e0;
        }
        .link-icon {
            width: 40px;
            height: 40px;
            background: #667eea;
            border-radius: 8px;
            display: flex;
            align-items: center;
            justify-content: center;
            margin-right: 1rem;
            color: white;
        }
        .link-info h3 {
            font-size: 1rem;
            font-weight: 600;
            margin-bottom: 0.25rem;
        }
        .link-info p {
            font-size: 0.875rem;
            color: #718096;
        }
        .badge {
            display: inline-block;
            background: #667eea;
            color: white;
            padding: 0.25rem 0.75rem;
            border-radius: 9999px;
            font-size: 0.75rem;
            font-weight: 600;
            margin-left: 0.5rem;
        }
        .footer {
            margin-top: 2rem;
            padding-top: 1.5rem;
            border-top: 1px solid #e2e8f0;
            text-align: center;
            color: #a0aec0;
            font-size: 0.875rem;
        }
        .footer a {
            color: #667eea;
            text-decoration: none;
        }
        .footer a:hover {
            text-decoration: underline;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>{{ config('app.name') }}</h1>
        <p class="subtitle">A minimal Laravel-style sample app for <strong>DStack</strong></p>
        
        <div class="links">
            <a href="{{ url('/api/ping') }}" class="link-card">
                <div class="link-icon">
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <path d="M22 16.92v3a2 2 0 0 1-2.18 2 19.79 19.79 0 0 1-8.63-3.07 19.5 19.5 0 0 1-6-6 19.79 19.79 0 0 1-3.07-8.67A2 2 0 0 1 4.11 2h3a2 2 0 0 1 2 1.72 12.84 12.84 0 0 0 .7 2.81 2 2 0 0 1-.45 2.11L8.09 9.91a16 16 0 0 0 6 6l1.27-1.27a2 2 0 0 1 2.11-.45 12.84 12.84 0 0 0 2.81.7A2 2 0 0 1 22 16.92z"></path>
                    </svg>
                </div>
                <div class="link-info">
                    <h3>API Ping <span class="badge">GET /api/ping</span></h3>
                    <p>Returns a simple JSON pong response with timestamp</p>
                </div>
            </a>
            
            <a href="{{ url('/api/health') }}" class="link-card">
                <div class="link-icon">
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
                        <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path>
                        <polyline points="22 4 12 14.01 9 11.01"></polyline>
                    </svg>
                </div>
                <div class="link-info">
                    <h3>Health Check <span class="badge">GET /api/health</span></h3>
                    <p>Returns service health status with dependency checks</p>
                </div>
            </a>
        </div>
        
        <div class="footer">
            <p>Powered by <a href="https://github.com/dgi-dev/DStack" target="_blank">DStack</a> — A Laragon-like local dev stack for PHP</p>
            <p>PHP {{ phpversion() }} • Laravel {{ app()->version() }}</p>
        </div>
    </div>
</body>
</html>