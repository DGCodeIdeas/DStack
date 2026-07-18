<?php
// DevStack managed virtual host
$domain = 'testapp.local';
header('Content-Type: text/html; charset=utf-8');
?>
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>DevStack &middot; <?= htmlspecialchars($domain) ?></title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 4rem; color: #222; }
    code { background: #f4f4f4; padding: 2px 6px; border-radius: 4px; }
  </style>
</head>
<body>
  <h1>DevStack</h1>
  <p>Virtual host <code><?= htmlspecialchars($domain) ?></code> is working.</p>
  <p>PHP version: <code><?= phpversion() ?></code></p>
</body>
</html>
