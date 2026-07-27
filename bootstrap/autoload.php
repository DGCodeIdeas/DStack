<?php

require __DIR__ . '/../vendor/autoload.php';

$app = require_once __DIR__ . '/app.php';

$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);

$kernel->bootstrap();

return $app;