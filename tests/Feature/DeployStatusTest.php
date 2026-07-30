<?php

namespace Tests\Feature;

use Tests\TestCase;

class DeployStatusTest extends TestCase
{
    protected string $statusFile;

    protected function setUp(): void
    {
        parent::setUp();
        $this->statusFile = tempnam(sys_get_temp_dir(), 'dstack_deploy_status_');
        config(['dstack.deploy_status_file' => $this->statusFile]);
    }

    protected function tearDown(): void
    {
        if (file_exists($this->statusFile)) {
            unlink($this->statusFile);
        }
        parent::tearDown();
    }

    public function test_deploy_status_endpoint_returns_404_when_file_missing(): void
    {
        unlink($this->statusFile);

        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(404)
            ->assertJson([
                'status' => 'not_found',
            ]);
    }

    public function test_deploy_status_endpoint_returns_complete_when_finished(): void
    {
        file_put_contents($this->statusFile, '{"phase":"complete","status":"done","finished_at":"2026-07-30T16:00:00Z"}');

        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(200)
            ->assertJson([
                'status' => 'complete',
                'current_phase' => 'complete',
            ]);
    }

    public function test_deploy_status_endpoint_returns_in_progress_when_running(): void
    {
        file_put_contents($this->statusFile, '{"phase":"nginx-config","status":"in_progress","started_at":"2026-07-30T15:00:00Z"}');

        $response = $this->getJson('/api/deploy-status');

        $response->assertStatus(200)
            ->assertJson([
                'status' => 'in_progress',
                'current_phase' => 'nginx-config',
            ]);
    }
}
