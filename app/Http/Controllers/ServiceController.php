<?php

namespace App\Http\Controllers;

use App\Services\DockerComposeService;
use Illuminate\Http\JsonResponse;

class ServiceController extends Controller
{
    public function index(DockerComposeService $docker): JsonResponse
    {
        return response()->json($docker->getAllStatus());
    }

    public function action(string $service, string $action, DockerComposeService $docker): JsonResponse
    {
        $knownServices = config('dstack.known_services', ['nginx', 'php', 'mysql', 'phpmyadmin', 'redis', 'all']);
        $validActions = ['start', 'stop', 'restart'];

        if (! in_array($service, $knownServices)) {
            return response()->json([
                'success' => false,
                'message' => "Unknown service '{$service}'. Valid services: ".implode(', ', $knownServices),
                'status' => null,
            ], 400);
        }

        if (! in_array($action, $validActions)) {
            return response()->json([
                'success' => false,
                'message' => "Unknown action '{$action}'. Valid: start, stop, restart",
                'status' => null,
            ], 400);
        }

        $result = $docker->{$action}($service);

        $status = null;
        if ($result['success']) {
            $status = $docker->getAllStatus();
        }

        return response()->json([
            'success' => $result['success'] ?? false,
            'message' => $result['message'] ?? '',
            'status' => $status,
        ], $result['success'] ? 200 : 400);
    }
}
