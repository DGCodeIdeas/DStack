<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use App\Services\VhostService;

class CreateVhostRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'domain' => ['required', 'string'],
            'framework' => ['in:php,laravel'],
            'root' => ['nullable', 'string'],
        ];
    }

    public function passedValidation(): void
    {
        $service = new VhostService();
        [$ok, $err] = $service::validateDomain($this->input('domain'));
        if (!$ok) {
            throw new \Illuminate\Validation\ValidationException(
                (new \Illuminate\Contracts\Validation\Validator(
                    new \Illuminate\Translation\Translator(
                        new \Illuminate\Translation\ArrayLoader(),
                        'en'
                    ),
                    ['domain' => [$err]],
                    ['domain' => $this->input('domain')]
                ))
            );
        }
    }
}