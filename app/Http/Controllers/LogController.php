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
        return response()->json($result, $result['success'] ? 200 : 400);
    }

    public function stream(string $service, LogService $log): JsonResponse
    {
        // Polling endpoint - same as snapshot, no SSE
        $lines = request()->query('lines', 50);
        $result = $log->getLogs($service, (int) $lines);
        return response()->json($result, $result['success'] ? 200 : 400);
    }
}