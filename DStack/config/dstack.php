<?php

return [

    /*
    |--------------------------------------------------------------------------
    | DStack Panel Configuration
    |--------------------------------------------------------------------------
    |
    | This configuration file contains all the settings for the DStack
    | Laravel panel including paths, timeouts, and service constants.
    | All service classes read from this file — never hardcode paths.
    |
    */

    /*
    |--------------------------------------------------------------------------
    | Paths
    |--------------------------------------------------------------------------
    */
    'root' => env('DSTACK_ROOT', '/opt/dstack-panel'),

    'compose_file' => env('DSTACK_DOCKER_COMPOSE_FILE'),

    'env_file' => env('DSTACK_DOCKER_ENV_FILE'),

    'vhosts_dir' => env('DSTACK_VHOSTS_DIR'),

    'ssl_dir' => env('DSTACK_SSL_DIR'),

    'projects_dir' => env('DSTACK_PROJECTS_DIR'),

    'backups_dir' => env('DSTACK_BACKUPS_DIR'),

    /*
    |--------------------------------------------------------------------------
    | Derived Paths
    |--------------------------------------------------------------------------
    */
    'nginx_container' => env('COMPOSE_PROJECT_NAME', 'devstack') . '-nginx',

    'tunnel_pid_file' => storage_path('tunnel.pid'),

    /*
    |--------------------------------------------------------------------------
    | Timeouts (seconds)
    |--------------------------------------------------------------------------
    */
    'compose_timeout' => 60,

    'backup_timeout' => 600,

    'ssl_timeout' => 120,

    /*
    |--------------------------------------------------------------------------
    | Service Lists
    |--------------------------------------------------------------------------
    */
    'known_services' => ['nginx', 'php', 'mysql', 'phpmyadmin', 'redis', 'all'],

    'protected_services' => ['nginx'],

    /*
    |--------------------------------------------------------------------------
    | Container Paths
    |--------------------------------------------------------------------------
    |
    | These must match the volume mounts defined in docker-compose.yml.
    |
    */
    'container_projects_root' => '/var/www/projects',

    'container_ssl_dir' => '/etc/nginx/ssl',
];