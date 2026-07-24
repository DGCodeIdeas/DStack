# DevStack PHP-FPM service
FROM php:${PHP_VERSION:-8.2}-fpm-alpine

# Install system build dependencies and runtime libraries required by PHP extensions
RUN apk add --no-cache \
        bash \
        git \
        unzip \
        curl \
        libxml2-dev \
        curl-dev \
        libzip-dev \
        zlib-dev \
        libpng-dev \
        libjpeg-turbo-dev \
        freetype-dev \
        imagemagick-dev \
        icu-dev \
        oniguruma-dev \
        $PHPIZE_DEPS

# Configure and install PHP extensions
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        pdo \
        pdo_mysql \
        mysqli \
        gd \
        zip \
        intl \
        bcmath \
        opcache \
        xml \
        mbstring \
        curl

# Install PECL extensions (redis, imagick) and enable them
RUN pecl install redis imagick \
    && docker-php-ext-enable redis imagick

# Install Composer (latest)
COPY --from=composer:latest /usr/bin/composer /usr/bin/composer

# Working directory for application code
WORKDIR /var/www

# Apply custom PHP configuration
COPY php.ini /usr/local/etc/php/conf.d/devstack.ini

# Run as the default www-data user
USER www-data

CMD ["php-fpm"]
