<?php

namespace App\Http\Requests;

use App\Services\VhostService;
use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Translation\ArrayLoader;
use Illuminate\Translation\Translator;
use Illuminate\Validation\ValidationException;

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
        $service = new VhostService;
        [$ok, $err] = $service::validateDomain($this->input('domain'));
        if (! $ok) {
            throw new ValidationException(
                (new Validator(
                    new Translator(
                        new ArrayLoader,
                        'en'
                    ),
                    ['domain' => [$err]],
                    ['domain' => $this->input('domain')]
                ))
            );
        }
    }
}
