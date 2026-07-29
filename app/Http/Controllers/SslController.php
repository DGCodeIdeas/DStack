<?php

namespace App\Http\Controllers;

use App\Http\Requests\CreateSslLetsEncryptRequest;
use App\Http\Requests\CreateSslLocalRequest;
use App\Services\SslService;
use Illuminate\Http\JsonResponse;

class SslController extends Controller
{
    public function index(SslService $ssl): JsonResponse
    {
        return response()->json($ssl->listCerts());
    }

    public function createLocal(CreateSslLocalRequest $request, SslService $ssl): JsonResponse
    {
        $result = $ssl->createMkcert($request->input('domain'));

        return response()->json($result, $result['success'] ? 200 : 400);
    }

    public function createLetsEncrypt(CreateSslLetsEncryptRequest $request, SslService $ssl): JsonResponse
    {
        $result = $ssl->createLetsEncrypt(
            $request->input('domain'),
            $request->input('email'),
            $request->input('mode', 'standalone'),
            $request->input('webroot_path')
        );

        return response()->json($result, $result['success'] ? 200 : 400);
    }
}
