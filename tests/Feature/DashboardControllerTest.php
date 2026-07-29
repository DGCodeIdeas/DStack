<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class DashboardControllerTest extends TestCase
{
    use RefreshDatabase;

    public function test_index_returns_dashboard_view(): void
    {
        $this->actingAsUser();

        $response = $this->get('/');

        $response->assertStatus(200);
        $response->assertViewIs('panel.index');
    }
}
