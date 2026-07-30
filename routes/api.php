<?php

use Illuminate\Support\Facades\Route;

Route::middleware(['web'])->group(function () {
    // API routes now live in routes/web.php under the `api` prefix
});
