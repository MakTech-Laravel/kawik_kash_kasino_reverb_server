FROM php:8.3-fpm

# Install system dependencies and PHP extensions
# sockets is required by ReactPHP / Laravel Reverb
RUN apt-get update && apt-get install -y \
    nginx \
    git \
    unzip \
    curl \
    libpng-dev \
    libonig-dev \
    libxml2-dev \
    libzip-dev \
    zip \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    supervisor \
    gnupg2 \
    ca-certificates \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install pdo_mysql mbstring zip exif pcntl gd sockets \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get update && apt-get install -y nodejs \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Install Composer
COPY --from=composer:2.6 /usr/bin/composer /usr/bin/composer

ENV COMPOSER_ALLOW_SUPERUSER=1
ENV COMPOSER_DISABLE_XDEBUG_WARN=1

WORKDIR /var/www

# Copy only Composer files first (clearer failures + better layer cache)
COPY composer.json composer.lock ./

# Install PHP deps from the lockfile (no Artisan scripts — no .env during Coolify build)
RUN composer install \
    --no-dev \
    --prefer-dist \
    --optimize-autoloader \
    --no-interaction \
    --no-scripts \
    --no-progress \
    || (echo "===== COMPOSER INSTALL FAILED =====" && composer diagnose || true && exit 2)

# Copy the rest of the application
COPY . .

# Custom PHP settings after Composer so install is not affected by app php.ini
COPY ./docker/php.ini /usr/local/etc/php/conf.d/custom.ini

# Ensure runtime directories exist
RUN mkdir -p storage/framework/{views,sessions,cache} \
    && mkdir -p storage/logs \
    && mkdir -p storage/app/public \
    && mkdir -p bootstrap/cache \
    && mkdir -p /var/log/supervisor

# Regenerate optimized autoloader now that full app source is present
RUN composer dump-autoload --optimize --no-scripts

# Discover packages with a throwaway key (Coolify injects real env at runtime)
RUN cp .env.example .env \
    && php artisan key:generate --force --no-interaction \
    && php artisan package:discover --ansi \
    && php artisan config:clear \
    && php artisan route:clear \
    && php artisan view:clear \
    && rm -f .env

# Frontend assets (need Vite/devDeps to build, then drop node_modules)
RUN npm ci || npm install \
    && npm run build \
    && rm -rf node_modules

# Ownership / permissions
RUN chown -R www-data:www-data /var/www \
    && chmod -R 775 storage \
    && chmod -R 775 bootstrap/cache \
    && touch storage/logs/laravel.log \
    && chown www-data:www-data storage/logs/laravel.log \
    && chmod 664 storage/logs/laravel.log

# Nginx + Supervisor
RUN rm -f /etc/nginx/sites-enabled/default
COPY ./docker/nginx.conf /etc/nginx/nginx.conf
COPY ./docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

EXPOSE 80 8081

CMD ["/usr/bin/supervisord", "-n"]
