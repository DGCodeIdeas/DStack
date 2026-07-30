<?php

namespace Tests\Feature;

use Tests\TestCase;

class DeployStatusTest extends TestCase
{
    protected function getStatusFilePath(): string
    {
        return base_path('.deploy-status');
    }

    public function test_deploy_status_endpoint_returns_404_when_file_missing(): void
    {
        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(404)
            ->assertJson([
                'status' => 'not_found',
            ]);
    }

    public function test_deploy_status_endpoint_returns_complete_when_finished(): void
    {
        $statusFile = $this->getStatusFilePath();
        file_put_contents($statusFile, '{"phase":"complete","status":"done","finished_at":"2026-07-30T16:00:00Z"}');

        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(200)
            ->assertJson([
                'status' => 'complete',
                'current_phase' => 'complete',
            ]);

        unlink($statusFile);
    }

    public function test_deploy_status_endpoint_returns_in_progress_when_running(): void
    {
        $statusFile = $this->getStatusFilePath();
        file_put_contents($statusFile, '{"phase":"nginx-config","status":"in_progress","started_at":"2026-07-30T15:00:00Z"}');

        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(200)
            ->assertJson([
                'status' => 'in_progress',
                'current_phase' => 'nginx-config',
            ]);

        unlink($statusFile);
    }
}
