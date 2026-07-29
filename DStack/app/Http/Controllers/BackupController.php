<?php

namespace App\Http\Controllers;

use App\Http\Requests\CreateBackupRequest;
use App\Http\Requests\RestoreBackupRequest;
use App\Services\BackupService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class BackupController extends Controller
{
    public function create(CreateBackupRequest $request, BackupService $backup): JsonResponse
    {
        $result = $backup->backup(
            $request->input('database', 'all'),
            $request->input('description', '')
        );
        return response()->json($result, $result['success'] ? 200 : 500);
    }

    public function index(BackupService $backup): JsonResponse
    {
        return response()->json($backup->listBackups());
    }

    public function restore(RestoreBackupRequest $request, BackupService $backup): JsonResponse
    {
        $result = $backup->restore(
            $request->input('backup_id'),
            $request->input('database')
        );

        if (isset($result['missing']) && $result['missing']) {
            return response()->json($result, 404);
        }

        return response()->json($result, $result['success'] ? 200 : 500);
    }
}