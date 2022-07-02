say "👋 Welcome to interactive Ruby on Whales installer 🐳.\n" \
    "Make sure you've read the guide: https://evilmartians.com/chronicles/ruby-on-whales-docker-for-ruby-rails-development"

DOCKER_DEV_ROOT = ".dockerdev"

INSTALL_RUBY_VERSION = "3.1.2"
INSTALL_POSTGRES_VERSION = "14"
INSTALL_REDIS_VERSION = "6.0"
INSTALL_NODE_VERSION = "16"

# Prepare variables and utility files
# Collect the app's metadata

app_name = Rails.application.class.name.partition('::').first.parameterize
# Load the project's deps and required Ruby version

ruby_version = INSTALL_RUBY_VERSION
gemspecs = {}

begin
  if File.file?("Gemfile.lock")
    bundler_parser = Bundler::LockfileParser.new(Bundler.read_file("Gemfile.lock"))
    gemspecs =  Hash[bundler_parser.specs.map { |spec| [spec.name, spec.version] }]
  end

  begin
    Gem::Version.new(ruby_version)
  rescue ArgumentError
    say "Invalid version. Please, try again"
    retry
  end
end
# Generates the Aptfile with system deps
DEFAULT_APTFILE = <<~CODE
  # An editor to work with credentials
  vim
CODE

begin
  deps = []

  aptfile = File.join(DOCKER_DEV_ROOT, "Aptfile")
  FileUtils.mkdir_p(File.dirname(aptfile))

  app_deps =
    if deps.empty?
      "\n"
    else
      (["# Application dependencies"] + deps + [""]).join("\n")
    end

  File.write(aptfile, DEFAULT_APTFILE + app_deps)
end
# Set up database related variables, create files

database_adapter = nil
database_url = nil

begin
  supported_adapters = %w(postgresql postgis postgres)

  config_path = "config/database.yml"

  if File.file?(config_path)
    require "yaml"
    maybe_database_adapter = begin
      ::YAML.load_file(config_path, aliases: true) || {}
    rescue ArgumentError
      ::YAML.load_file(config_path) || {}
    end.dig("development", "adapter")
  end

  selected_database_adapter = maybe_database_adapter

  if supported_adapters.include?(selected_database_adapter)
    database_adapter = selected_database_adapter
  else
    say_status :warn, "Unfortunately, we do no support #{selected_database_adapter} yet. Please, configure it yourself"
  end
end
# Specify PostgreSQL version

postgres_base_image = "postgres"

postgres_version = INSTALL_POSTGRES_VERSION

POSTGRES_ADAPTERS = %w[postgres postgresql postgis]

if POSTGRES_ADAPTERS.include?(database_adapter)
  begin
    database_url = "#{database_adapter}://postgres:postgres@postgres:5432"

    if database_adapter == "postgis"
      postgres_base_image = "postgis/postgis"
    end
  end
end
# Node/Yarn configuration
# TODO: Read Node/Yarn versions from .nvmrc/package.json.

yarn_version = "latest"

node_version = INSTALL_NODE_VERSION

# Redis info

redis_version = INSTALL_REDIS_VERSION

# Generate configuration
file "#{DOCKER_DEV_ROOT}/Dockerfile", ERB.new(
  *[
<<~'CODE'
ARG RUBY_VERSION
ARG DISTRO_NAME=bullseye

FROM ruby:$RUBY_VERSION-slim-$DISTRO_NAME

ARG DISTRO_NAME

# Common dependencies
RUN apt-get update -qq \
  && DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    build-essential \
    gnupg2 \
    curl \
    less \
    git \
  && apt-get clean \
  && rm -rf /var/cache/apt/archives/* \
  && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
  && truncate -s 0 /var/log/*log
<% if postgres_version %>

ARG PG_MAJOR
RUN curl -sSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgres-archive-keyring.gpg \
  && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/postgres-archive-keyring.gpg] https://apt.postgresql.org/pub/repos/apt/" \
    $DISTRO_NAME-pgdg main $PG_MAJOR | tee /etc/apt/sources.list.d/postgres.list > /dev/null
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    libpq-dev \
    postgresql-client-$PG_MAJOR \
    && apt-get clean \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && truncate -s 0 /var/log/*log
<% end %>
<% if node_version %>

ARG NODE_MAJOR
RUN curl -sL https://deb.nodesource.com/setup_$NODE_MAJOR.x | bash -
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    nodejs \
    && apt-get clean \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && truncate -s 0 /var/log/*log
<% if yarn_version == 'latest' %>

RUN npm install -g yarn
<% else %>

ARG YARN_VERSION
RUN npm install -g yarn@$YARN_VERSION
<% end %>
<% end %>

# Application dependencies
# We use an external Aptfile for this, stay tuned
COPY Aptfile /tmp/Aptfile
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get -yq dist-upgrade && \
  DEBIAN_FRONTEND=noninteractive apt-get install -yq --no-install-recommends \
    $(grep -Ev '^\s*#' /tmp/Aptfile | xargs) \
    && apt-get clean \
    && rm -rf /var/cache/apt/archives/* \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* \
    && truncate -s 0 /var/log/*log

# Configure bundler
ENV LANG=C.UTF-8 \
  BUNDLE_JOBS=4 \
  BUNDLE_RETRY=3

# Store Bundler settings in the project's root
ENV BUNDLE_APP_CONFIG=.bundle

# Uncomment this line if you want to run binstubs without prefixing with `bin/` or `bundle exec`
# ENV PATH /app/bin:$PATH

# Upgrade RubyGems and install the latest Bundler version
RUN gem update --system && \
    gem install bundler

# Create a directory for the app code
RUN mkdir -p /app
WORKDIR /app

# Document that we're going to expose port 3000
EXPOSE 3000
# Use Bash as the default command
CMD ["/usr/bin/bash"]
CODE
], trim_mode: "<>").result(binding)
file "#{DOCKER_DEV_ROOT}/compose.yml", ERB.new(
  *[
<<~'CODE'
x-app: &app
  build:
    context: .
    args:
      RUBY_VERSION: '<%= ruby_version %>'
<% if postgres_version %>
      PG_MAJOR: '<%= postgres_version.split('.', 2).first %>'
<% end %>
<% if node_version %>
      NODE_MAJOR: '<%= node_version.split('.', 2).first %>'
<% end %>
<% if yarn_version && yarn_version != 'latest' %>
      YARN_VERSION: '<%= yarn_version %>'
<% end %>
  image: <%= app_name %>-dev:1.0.0
  environment: &env
<% if node_version %>
    NODE_ENV: ${NODE_ENV:-development}
<% end %>
    RAILS_ENV: ${RAILS_ENV:-development}
  tmpfs:
    - /tmp
    - /app/tmp/pids

x-backend: &backend
  <<: *app
  stdin_open: true
  tty: true
  volumes:
    - ..:/app:cached
    - bundle:/usr/local/bundle
    - rails_cache:/app/tmp/cache
<% if File.directory?("app/assets") %>
    - assets:/app/public/assets
<% end %>
<% if node_version %>
    - node_modules:/app/node_modules
<% end %>
<% if gemspecs.key?("webpacker") %>
    - packs:/app/public/packs
    - packs-test:/app/public/packs-test
<% end %>
    - history:/usr/local/hist
<% if postgres_version %>
    - ./.psqlrc:/root/.psqlrc:ro
<% end %>
    - ./.bashrc:/root/.bashrc:ro
  environment: &backend_environment
    <<: *env
<% if redis_version %>
    REDIS_URL: redis://redis:6379/
<% end %>
<% if database_url %>
    DATABASE_URL: postgres://postgres:postgres@postgres:5432
<% end %>
<% if gemspecs.key?("webpacker") %>
    WEBPACKER_DEV_SERVER_HOST: webpacker
<% end %>
    MALLOC_ARENA_MAX: 2
    WEB_CONCURRENCY: ${WEB_CONCURRENCY:-1}
    BOOTSNAP_CACHE_DIR: /usr/local/bundle/_bootsnap
    XDG_DATA_HOME: /app/tmp/caches
<% if yarn_version %>
    YARN_CACHE_FOLDER: /app/node_modules/.yarn-cache
<% end %>
    HISTFILE: /usr/local/hist/.bash_history
<% if postgres_version %>
    PSQL_HISTFILE: /usr/local/hist/.psql_history
<% end %>
    IRB_HISTFILE: /usr/local/hist/.irb_history
    EDITOR: vi
<% if postgres_version || redis_version %>
  depends_on:
<% if postgres_version %>
    postgres:
      condition: service_healthy
<% end %>
<% if redis_version %>
    redis:
      condition: service_healthy
<% end %>
<% end %>

services:
  rails:
    <<: *backend
    command: bundle exec rails

  web:
    <<: *backend
    command: bundle exec rails server -b 0.0.0.0
    ports:
      - '3000:3000'
<% if gemspecs.key?("webpacker") || gemspecs.key?("sidekiq") %>
    depends_on:
<% if gemspecs.key?("webpacker") %>
      webpacker:
        condition: service_started
<% end %>
<% if gemspecs.key?("sidekiq") %>
      sidekiq:
        condition: service_started
<% end %>
<% end %>
<% if gemspecs.key?("sidekiq") %>

  sidekiq:
    <<: *backend
    command: bundle exec sidekiq
<% end %>
<% if postgres_version %>

  postgres:
    image: postgres:<%= postgres_version %>
    volumes:
      - .psqlrc:/root/.psqlrc:ro
      - postgres:/var/lib/postgresql/data
      - history:/user/local/hist
    environment:
      PSQL_HISTFILE: /user/local/hist/.psql_history
      POSTGRES_PASSWORD: postgres
    ports:
      - 5432
    healthcheck:
      test: pg_isready -U postgres -h 127.0.0.1
      interval: 5s
<% end %>
<% if redis_version %>

  redis:
    image: redis:<%= redis_version %>-alpine
    volumes:
      - redis:/data
    ports:
      - 6379
    healthcheck:
      test: redis-cli ping
      interval: 1s
      timeout: 3s
      retries: 30
<% end %>
<% if gemspecs.key?("webpacker") %>

  webpacker:
    <<: *app
    command: bundle exec ./bin/webpack-dev-server
    ports:
      - '3035:3035'
    volumes:
      - ..:/app:cached
      - bundle:/usr/local/bundle
      - node_modules:/app/node_modules
      - packs:/app/public/packs
      - packs-test:/app/public/packs-test
    environment:
      <<: *env
      WEBPACKER_DEV_SERVER_HOST: 0.0.0.0
      YARN_CACHE_FOLDER: /app/node_modules/.yarn-cache
<% end %>

volumes:
  bundle:
<% if node_version %>
  node_modules:
<% end %>
  history:
  rails_cache:
<% if postgres_version %>
  postgres:
<% end %>
<% if redis_version %>
  redis:
<% end %>
<% if File.directory?("app/assets") %>
  assets:
<% end %>
<% if gemspecs.key?("webpacker") %>
  packs:
  packs-test:
<% end %>
CODE
], trim_mode: "<>").result(binding)
file "dip.yml", ERB.new(
  *[
<<~'CODE'
version: '7.1'

# Define default environment variables to pass
# to Docker Compose
environment:
  RAILS_ENV: development

compose:
  files:
    - <%= DOCKER_DEV_ROOT %>/compose.yml
  project_name: <%= app_name %>

interaction:
  # This command spins up a Rails container with the required dependencies (such as databases),
  # and opens a terminal within it.
  runner:
    description: Open a Bash shell within a Rails container (with dependencies up)
    service: rails
    command: /bin/bash

  # Run a Rails container without any dependent services (useful for non-Rails scripts)
  bash:
    description: Run an arbitrary script within a container (or open a shell without deps)
    service: rails
    command: /bin/bash
    compose_run_options: [ no-deps ]

  # A shortcut to run Bundler commands
  bundle:
    description: Run Bundler commands
    service: rails
    command: bundle
    compose_run_options: [ no-deps ]
<% if gemspecs.key?("rspec") %>

  # A shortcut to run RSpec (which overrides the RAILS_ENV)
  rspec:
    description: Run RSpec commands
    service: rails
    environment:
      RAILS_ENV: test
    command: bundle exec rspec
<% end %>

  rails:
    description: Run Rails commands
    service: rails
    command: bundle exec rails
    subcommands:
      s:
        description: Run Rails server at http://localhost:3000
        service: web
        compose:
          run_options: [ service-ports, use-aliases ]
<% if !gemspecs.key?("rspec") %>
      test:
        description: Run unit tests
        service: rails
        command: bundle exec rails test
        environment:
          RAILS_ENV: test
<% end %>
<% if yarn_version %>

  yarn:
    description: Run Yarn commands
    service: rails
    command: yarn
    compose_run_options: [ no-deps ]
<% end %>
<% if postgres_version %>

  psql:
    description: Run Postgres psql console
    service: postgres
    default_args: <%= app_name %>_development
    command: psql -h postgres -U postgres
<% end %>
<% if redis_version %>

  'redis-cli':
    description: Run Redis console
    service: redis
    command: redis-cli -h redis
<% end %>

provision:
  # We need the `|| true` part because some docker-compose versions
  # cannot down a non-existent container without an error,
  # see https://github.com/docker/compose/issues/9426
  - dip compose down --volumes || true
<% if postgres_version %>
  - dip compose up -d postgres
<% end %>
<% if redis_version %>
  - dip compose up -d redis
<% end %>
  - dip bash -c bin/setup
CODE
], trim_mode: "<>").result(binding)

file "#{DOCKER_DEV_ROOT}/.bashrc", ERB.new(
  *[
<<~'CODE'
alias be="bundle exec"
CODE
], trim_mode: "<>").result(binding)
if postgres_version
  file "#{DOCKER_DEV_ROOT}/.psqlrc", ERB.new(
  *[
<<~'CODE'
-- Don't display the "helpful" message on startup.
\set QUIET 1

-- Allow specifying the path to history file via `PSQL_HISTFILE` env variable
-- (and fallback to the default $HOME/.psql_history otherwise)
\set HISTFILE `[ -z $PSQL_HISTFILE ] && echo $HOME/.psql_history || echo $PSQL_HISTFILE`

-- Show how long each query takes to execute
\timing

-- Use best available output format
\x auto

-- Verbose error reports
\set VERBOSITY verbose

-- If a command is run more than once in a row,
-- only store it once in the history
\set HISTCONTROL ignoredups
\set COMP_KEYWORD_CASE upper

-- By default, NULL displays as an empty space. Is it actually an empty
-- string, or is it null? This makes that distinction visible
\pset null '[NULL]'

\unset QUIET
CODE
], trim_mode: "<>").result(binding)
end

file "#{DOCKER_DEV_ROOT}/README.md", ERB.new(
  *[
<<~'CODE'
# Docker for Development

Source: [Ruby on Whales: Dockerizing Ruby and Rails development](https://evilmartians.com/chronicles/ruby-on-whales-docker-for-ruby-rails-development).

## Installation

- Docker installed.

For MacOS just use the [official app](https://docs.docker.com/engine/installation/mac/).

- [`dip`](https://github.com/bibendi/dip) installed.

You can install `dip` as Ruby gem:

```sh
gem install dip
```

## Provisioning

When using Dip it could be done with a single command:

```sh
dip provision
```

## Running

```sh
dip rails s
```

## Developing with Dip

### Useful commands

```sh
# run rails console
dip rails c

# run rails server with debugging capabilities (i.e., `debugger` would work)
dip rails s

# or run the while web app (with all the dependencies)
dip up web

# run migrations
dip rails db:migrate

# pass env variables into application
dip VERSION=20100905201547 rails db:migrate:down

# simply launch bash within app directory (with dependencies up)
dip runner

# execute an arbitrary command via Bash
dip bash -c 'ls -al tmp/cache'

# Additional commands

# update gems or packages
dip bundle install
<% if yarn_version %>
dip yarn install
<% end %>
<% if postgres_version %>

# run psql console
dip psql
<% end %>
<% if redis_version %>

# run Redis console
dip redis-cli
<% end %>

# run tests
<% if gemspecs.key?("rspec") %>
# TIP: `dip rspec` is already auto prefixed with `RAILS_ENV=test`
dip rspec spec/path/to/single/test.rb:23
<% else %>
# TIP: `dip rails test` is already auto prefixed with `RAILS_ENV=test`
dip rails test
<% end %>

# shutdown all containers
dip down
```

### Development flow

Another way is to run `dip <smth>` for every interaction. If you prefer this way and use ZSH, you can reduce the typing
by integrating `dip` into your session:

```sh
$ dip console | source /dev/stdin
# no `dip` prefix is required anymore!
$ rails c
Loading development environment (Rails 7.0.1)
pry>
```
CODE
], trim_mode: "<>").result(binding)

todos = [
  "📝  Important things to take care of:",
  "  - Make sure you have `ENV[\"RAILS_ENV\"] = \"test\"` (not `ENV[\"RAILS_ENV\"] ||= \"test\"`) in your test helper."
]

if database_url
  todos << "  - Don't forget to add `url: \<\%= ENV[\"DATABASE_URL\"] \%\>` to your database.yml"
end

if todos.any?
  say_status(:warn, todos.join("\n"))
end

say_status :info, "✅  You're ready to sail! Check out #{DOCKER_DEV_ROOT}/README.md or run `dip provision && dip up web` 🚀"
