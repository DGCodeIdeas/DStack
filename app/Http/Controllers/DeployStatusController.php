<?php

namespace App\Http\Controllers;

use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\File;

class DeployStatusController extends Controller
{
    public function index(): JsonResponse
    {
        $statusFile = config('dstack.deploy_status_file', '/var/log/dstack-panel/deploy-status');

        if (! File::exists($statusFile)) {
            return response()->json([
                'status' => 'not_found',
                'message' => 'Deployment status file not found. The instance may still be provisioning.',
            ], 404);
        }

        $lines = File::lines($statusFile);
        $entries = [];

        foreach ($lines as $line) {
            $decoded = json_decode(trim($line), true);
            if ($decoded) {
                $entries[] = $decoded;
            }
        }

        $current = end($entries);
        $isComplete = isset($current['phase']) && $current['phase'] === 'complete';

        return response()->json([
            'status' => $isComplete ? 'complete' : 'in_progress',
            'current_phase' => $current['phase'] ?? 'unknown',
            'entries' => $entries,
        ]);
    }
}
