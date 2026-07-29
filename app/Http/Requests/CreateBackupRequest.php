<?php

namespace App\Http\Requests;

use App\Services\BackupService;
use Illuminate\Contracts\Validation\Validator;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Translation\ArrayLoader;
use Illuminate\Translation\Translator;
use Illuminate\Validation\ValidationException;

class CreateBackupRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'database' => ['nullable', 'string'],
            'description' => ['nullable', 'string'],
        ];
    }

    public function passedValidation(): void
    {
        $database = $this->input('database', 'all');
        $service = new BackupService;
        if (! $service::validateDbName($database)) {
            throw new ValidationException(
                (new Validator(
                    new Translator(
                        new ArrayLoader,
                        'en'
                    ),
                    ['database' => ['Invalid database name']],
                    ['database' => $database]
                ))
            );
        }
    }
}
