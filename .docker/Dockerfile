FROM dunglas/frankenphp:php8.2-alpine

ENV SERVER_NAME="http://:8888, http://:8989"

WORKDIR /app

# Install runtime dependencies
RUN apk add --no-cache \
    libjpeg-turbo \
    libpng \
    libwebp \
    icu \
    libzip \
    zlib \
    oniguruma \
    curl \
    mysql-client \
    zip \
    unzip

# Install build dependencies + Xdebug + FIX OPCACHE JIT
RUN apk add --no-cache --virtual .build-deps \
    $PHPIZE_DEPS \
    icu-dev \
    libzip-dev \
    zlib-dev \
    libjpeg-turbo-dev \
    libpng-dev \
    libwebp-dev \
    oniguruma-dev \
    linux-headers \
 && pecl install xdebug \
 && docker-php-ext-enable xdebug \
 && docker-php-ext-configure opcache --disable-opcache-jit \
 && docker-php-ext-install -j$(nproc) \
    pdo \
    pdo_mysql \
    zip \
    intl \
    opcache \
    gd \
 && apk del .build-deps \
 && rm -rf /var/cache/apk/* /tmp/*

# Tambahkan konfigurasi Xdebug
COPY ./xdebug.ini /usr/local/etc/php/conf.d/xdebug.ini

# Install Composer
RUN curl -sS https://getcomposer.org/installer | php \
  -- --install-dir=/usr/bin --filename=composer

EXPOSE 8888 8989 9003

