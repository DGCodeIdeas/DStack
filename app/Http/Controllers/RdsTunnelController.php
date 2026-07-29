<?php

namespace App\Http\Controllers;

use App\Http\Requests\RdsTunnelStartRequest;
use App\Services\RdsTunnelService;
use Illuminate\Http\JsonResponse;

class RdsTunnelController extends Controller
{
    public function start(RdsTunnelStartRequest $request, RdsTunnelService $tunnel): JsonResponse
    {
        $result = $tunnel->connect(
            $request->input('ec2_host'),
            $request->input('ec2_user'),
            $request->input('ec2_key_path'),
            $request->input('rds_host'),
            $request->input('rds_port', 3306),
            $request->input('local_port', 3307)
        );

        return response()->json($result, $result['success'] ? 200 : 400);
    }

    public function stop(RdsTunnelService $tunnel): JsonResponse
    {
        $result = $tunnel->disconnect();

        return response()->json($result);
    }

    public function status(RdsTunnelService $tunnel): JsonResponse
    {
        return response()->json($tunnel->getStatus());
    }
}
