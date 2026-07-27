<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use App\Services\BackupService;

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
        $service = new BackupService();
        if (!$service::validateDbName($database)) {
            throw new \Illuminate\Validation\ValidationException(
                (new \Illuminate\Contracts\Validation\Validator(
                    new \Illuminate\Translation\Translator(
                        new \Illuminate\Translation\ArrayLoader(),
                        'en'
                    ),
                    ['database' => ['Invalid database name']],
                    ['database' => $database]
                ))
            );
        }
    }
}