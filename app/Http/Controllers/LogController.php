<?php

namespace App\Http\Controllers;

use App\Services\LogService;
use Illuminate\Http\JsonResponse;

class LogController extends Controller
{
    public function index(string $service, LogService $log): JsonResponse
    {
        $lines = request()->query('lines', 50);
        $result = $log->getLogs($service, (int) $lines);

        return response()->json($result);
    }

    public function stream(string $service, LogService $log): JsonResponse
    {
        $lines = request()->query('lines', 50);
        $result = $log->getLogs($service, (int) $lines);

        return response()->json($result);
    }
}
