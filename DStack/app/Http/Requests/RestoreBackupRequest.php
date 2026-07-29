<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use App\Services\BackupService;

class RestoreBackupRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'backup_id' => ['required', 'string'],
            'database' => ['nullable', 'string'],
        ];
    }

    public function passedValidation(): void
    {
        $database = $this->input('database');
        if ($database !== null) {
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
}