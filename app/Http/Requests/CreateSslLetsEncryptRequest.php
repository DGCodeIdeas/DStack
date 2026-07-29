<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class CreateSslLetsEncryptRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'domain' => ['required', 'string'],
            'email' => ['required', 'email'],
            'mode' => ['in:standalone,webroot'],
            'webroot_path' => ['required_if:mode,webroot', 'string'],
        ];
    }
}
