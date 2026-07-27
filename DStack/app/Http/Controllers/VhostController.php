<?php

namespace App\Http\Controllers;

use App\Http\Requests\CreateVhostRequest;
use App\Services\VhostService;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

class VhostController extends Controller
{
    public function index(VhostService $vhost): JsonResponse
    {
        return response()->json($vhost->listAll());
    }

    public function store(CreateVhostRequest $request, VhostService $vhost): JsonResponse
    {
        $result = $vhost->create(
            $request->input('domain'),
            $request->input('root'),
            $request->input('framework', 'php')
        );
        return response()->json($result, $result['success'] ? 200 : 400);
    }

    public function destroy(string $domain, VhostService $vhost): JsonResponse
    {
        $result = $vhost->delete($domain);

        if (isset($result['missing']) && $result['missing']) {
            return response()->json($result, 404);
        }

        return response()->json($result, $result['success'] ? 200 : 400);
    }
}