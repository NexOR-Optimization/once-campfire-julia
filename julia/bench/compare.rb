#!/usr/bin/env ruby
# Add Julia to the shared full-server comparison without editing its checkout.
# The adapter changes registration, process configuration and scheduling only;
# the load generator, response contracts and persisted-write audits are retained.
require "digest"
require "json"

module CampfireComparisonAdapter
  ROOT = File.expand_path("../..", __dir__)
  FILE = File.expand_path(__FILE__)
  SOURCE = File.expand_path(ENV.fetch("JULIA_SOURCE", ROOT))
  RUNTIME_PATHS = %w[
    julia/Project.toml julia/Manifest.toml julia/server.jl julia/Dockerfile
    julia/bin julia/src julia/assets app/javascript app/assets app/views/pwa
    vendor/javascript
  ].freeze

  def self.runtime_digest(root)
    files = RUNTIME_PATHS.flat_map do |relative|
      path = File.join(root, relative)
      File.directory?(path) ? Dir.glob(File.join(path, "**", "*")) : [path]
    end.select { |path| File.file?(path) }.sort
    raise "Julia runtime source is missing: #{root}" if files.empty?
    digest = Digest::SHA256.new
    files.each do |path|
      relative = path.delete_prefix(root + "/")
      digest << relative << "\0" << Digest::SHA256.file(path).hexdigest << "\0"
    end
    digest.hexdigest
  end

  def self.replace_once(source, before, after)
    occurrences = source.scan(Regexp.new(Regexp.escape(before))).length
    raise "Unsupported upstream comparison: expected one occurrence, found #{occurrences}: #{before.inspect}" unless occurrences == 1
    source.sub(before, after)
  end

  def self.container_cgroup(container)
    output, _, status = Open3.capture3("docker", "inspect", "-f", "{{.State.Pid}}", container)
    return unless status.success?
    pid = Integer(output.strip)
    relative = File.readlines("/proc/#{pid}/cgroup").find { |line| line.start_with?("0::") }&.split("::", 2)&.last&.strip
    return unless relative
    path = File.expand_path(relative.delete_prefix("/"), "/sys/fs/cgroup")
    path if path.start_with?("/sys/fs/cgroup/") && File.readable?(File.join(path, "cpu.stat"))
  rescue SystemCallError, ArgumentError
    nil
  end

  def self.resource_sample(path)
    return unless path
    cpu = File.readlines(File.join(path, "cpu.stat")).to_h { |line| line.split }
    {
      time: Process.clock_gettime(Process::CLOCK_MONOTONIC),
      usage_usec: Integer(cpu.fetch("usage_usec")),
      memory_current_bytes: Integer(File.read(File.join(path, "memory.current"))),
      memory_lifetime_peak_bytes: Integer(File.read(File.join(path, "memory.peak")))
    }
  rescue SystemCallError, ArgumentError, KeyError
    nil
  end

  def self.add_resources(value, before, after)
    return unless before && after
    elapsed = after.fetch(:time) - before.fetch(:time)
    used = after.fetch(:usage_usec) - before.fetch(:usage_usec)
    return unless elapsed.positive? && used >= 0
    value["server_resources"] = {
      cpu_percent: 100.0 * used / (1_000_000 * elapsed), cpu_usage_usec: used,
      sample_elapsed_seconds: elapsed,
      memory_current_bytes: after.fetch(:memory_current_bytes),
      memory_lifetime_peak_bytes: after.fetch(:memory_lifetime_peak_bytes)
    }
  end

  def self.adapt(original)
    source = original.dup
    substitutions = [
      # OptionParser automatically exposes keys in the upstream options hash.
      ['rounds: 3, duration: 8,', 'rounds: 3, duration: 8, warmup: 5,'],
      ['allowed = %w[rails django laravel express express-bun elixir go rust c cpp]',
       'allowed = %w[rails django laravel express express-bun elixir go rust c cpp julia]'],
      ['raise "use at least two rounds" unless options[:rounds] >= 2',
       'raise "use at least two rounds" unless options[:rounds] >= 2' + "\n" +
       'raise "warmup must be positive" unless options[:warmup].positive?'],
      # Three apps over three rounds each occupy every position exactly once.
      ['order = iteration.even? ? apps : apps.reverse', 'order = apps.rotate(iteration % apps.length)'],
      # Read cgroup counters outside the existing load-generator timing block.
      # There is no sampler task, polling or process inside the server cgroup.
      ["lg = ->(*args) do\n  started = clock", "server_cgroup = nil\nlg = ->(*args) do\n  resource_before = args.first == \"http\" ? CampfireComparisonAdapter.resource_sample(server_cgroup) : nil\n  started = clock"],
      ['value["generator_cpu_percent"] = 100.0 * (cpu_after.cutime + cpu_after.cstime - cpu_before.cutime - cpu_before.cstime) / (clock - started)',
       'value["generator_cpu_percent"] = 100.0 * (cpu_after.cutime + cpu_after.cstime - cpu_before.cutime - cpu_before.cstime) / (clock - started)' + "\n    " +
       'CampfireComparisonAdapter.add_resources(value, resource_before, CampfireComparisonAdapter.resource_sample(server_cgroup))'],
      ['source = File.join(options[:workspace], kind == "rails" ? "once-campfire" : "once-campfire-#{kind}")',
       'source = kind == "julia" ? CampfireComparisonAdapter::SOURCE : File.join(options[:workspace], kind == "rails" ? "once-campfire" : "once-campfire-#{kind}")'],
      # Include untracked Julia implementation files in source identity.
      ['raise "#{app}: source changed between rounds" if metadata[:source_revisions].key?(app)',
       'source_identity[:runtime_source_sha256] = CampfireComparisonAdapter.runtime_digest(source) if kind == "julia"' + "\n      " +
       'raise "#{app}: source changed between rounds" if metadata[:source_revisions].key?(app)'],
      # The image runs as uid 1000. Only the disposable fixture copy is changed;
      # upstream's chmod after readiness is too late for Julia to open this DB.
      ['FileUtils.mkdir_p(File.join(data, "logs"))',
       'FileUtils.mkdir_p(File.join(data, "logs"))' + "\n      " +
       'FileUtils.chmod_R("a+rwX", data) if kind == "julia"'],
      # The shared harness already mounts these paths for every implementation.
      # Runtime-specific overrides are applied afterward, exactly as upstream.
      ['config.merge!(JSON.parse(ENV.fetch("#{env_name.(app)}_BENCH_ENV", "{}")))', <<~'RUBY'.strip],
        if kind == "julia"
          config.merge!("DATABASE_PATH" => "/rails/storage/db/production.sqlite3",
            "STORAGE_PATH" => "/rails/storage/files", "PORT" => options[:port].to_s,
            "CAMPFIRE_HOST" => "0.0.0.0", "CAMPFIRE_ORIGIN" => base,
            "JULIA_NUM_THREADS" => "auto")
        end
        config.merge!(JSON.parse(ENV.fetch("#{env_name.(app)}_BENCH_ENV", "{}")))
      RUBY
      ['when "go" then {processes: 1, cable: "native websocket", jobs: "in-process"}',
       'when "julia" then {processes: 1, threads: config.fetch("JULIA_NUM_THREADS"), database: "one serialized connection", cable: "native Action Cable", jobs: "in-process", gc: "enabled"}' + "\n      " +
       'when "go" then {processes: 1, cable: "native websocket", jobs: "in-process"}'],
      ["run(*command)\n      client = BenchmarkHTTPClient.new(base)", "run(*command)\n      server_cgroup = CampfireComparisonAdapter.container_cgroup(container)\n      client = BenchmarkHTTPClient.new(base)"],
      ['"--conc", "4", "--duration", "2")', '"--conc", "4", "--duration", options[:warmup].to_s)'],
      ['sql = ->(db, query) do', <<~'RUBY'.strip]
        metadata[:adapter] = CampfireComparisonAdapter.metadata.merge(
          warmup_seconds: options[:warmup], round_order: "rotate-left-one-per-round",
          per_round_order: options[:rounds].times.map { |i| apps.rotate(i % apps.length) })
        sql = ->(db, query) do
      RUBY
    ]
    substitutions.each { |before, after| source = replace_once(source, before, after) }
    source
  end

  def self.metadata
    @metadata
  end

  def self.prepare(path)
    original = File.read(path)
    adapted = adapt(original)
    @metadata = {
      name: "campfire-julia-comparison-v1", source: FILE,
      source_sha256: Digest::SHA256.file(FILE).hexdigest,
      upstream_comparison_sha256: Digest::SHA256.hexdigest(original),
      adapted_comparison_sha256: Digest::SHA256.hexdigest(adapted),
      adaptations: %w[julia-registration julia-source-identity julia-runtime-environment
        julia-topology disposable-julia-storage-permissions configurable-warmup
        rotating-round-order host-cgroup-resource-counters],
      server_resources: "best-effort host cgroup-v2 counters around complete loadgen invocations; memory peak is container lifetime",
      response_contracts: "unchanged upstream", persisted_write_audits: "unchanged upstream",
      load_generator: "unchanged upstream"
    }
    adapted
  end

  def self.run(argv)
    verification = argv.shift
    abort "Usage: ruby julia/bench/compare.rb VERIFICATION_CHECKOUT [upstream benchmark options, --warmup SECONDS]" unless verification
    path = File.join(File.expand_path(verification), "bench/compare.rb")
    source = prepare(path)
    # Preserve the same cross-process lock used by upstream bin/benchmark.
    lock = File.open(File.join(ENV.fetch("TMPDIR", "/tmp"), "once-campfire-verification-benchmark.lock"), "a")
    abort "Another Campfire benchmark is running; wait for it to finish" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
    # Original filename preserves require_relative and __dir__ resolution.
    eval(source, TOPLEVEL_BINDING, path, 1)
  ensure
    lock&.close
  end
end

CampfireComparisonAdapter.run(ARGV) if $PROGRAM_NAME == __FILE__
