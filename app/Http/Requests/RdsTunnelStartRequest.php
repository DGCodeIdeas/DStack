<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class RdsTunnelStartRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'ec2_host' => ['required', 'string'],
            'ec2_user' => ['required', 'string'],
            'ec2_key_path' => ['required', 'string'],
            'rds_host' => ['required', 'string'],
            'rds_port' => ['integer', 'min:1', 'max:65535'],
            'local_port' => ['integer', 'min:1', 'max:65535'],
        ];
    }
}
