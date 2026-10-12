#!/usr/bin/env ruby
# Run the upstream contracts and load generator without modifying the harness.
# This is a correctness gate; fixed request counts are not a throughput study.
require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "tmpdir"

options = { port: 3903, requests: 100, concurrency: 4 }
parser = OptionParser.new do |arguments|
  arguments.banner = "Usage: ruby julia/bench/conformance.rb VERIFICATION_CHECKOUT FIXTURE [options]"
  arguments.on("--port PORT", Integer) { |v| options[:port] = v }
  arguments.on("--requests COUNT", Integer) { |v| options[:requests] = v }
  arguments.on("--concurrency COUNT", Integer) { |v| options[:concurrency] = v }
  arguments.on("--output DIRECTORY") { |v| options[:output] = File.expand_path(v) }
end
parser.parse!
abort parser.to_s unless ARGV.length == 2
verification, fixture = ARGV.map { |path| File.expand_path(path) }
abort "Request and concurrency counts must be positive" unless options.values_at(:requests, :concurrency).all?(&:positive?)
loadgen = ENV.fetch("LOADGEN", File.join(verification, "loadgen/target/release/loadgen"))
abort "Build the upstream load generator first: cargo build --release --locked --manifest-path #{verification}/loadgen/Cargo.toml" unless File.executable?(loadgen)
require File.join(verification, "bench/contracts")
require File.join(verification, "bench/validate_acks")

output = options[:output] || Dir.mktmpdir("campfire-julia-conformance-")
abort "Output directory must be absent or empty" if Dir.exist?(output) && !Dir.empty?(output)
FileUtils.mkdir_p(output)
FileUtils.cp_r(File.join(fixture, "db"), File.join(output, "db"))
FileUtils.cp_r(File.join(fixture, "storage"), File.join(output, "storage"))
database = File.join(output, "db/production.sqlite3")
labels = JSON.parse(File.read(File.join(fixture, "labels.json")))
environment = File.readlines(File.join(fixture, "reference.env")).filter_map do |line|
  match = line.strip.match(/\A([A-Z][A-Z0-9_]*)=(.*)\z/)
  [match[1], match[2]] if match
end.to_h
base = "http://127.0.0.1:#{options[:port]}"
environment.merge!("STORAGE_PATH" => File.join(output, "storage"), "CAMPFIRE_ORIGIN" => base, "CAMPFIRE_HOST" => "127.0.0.1")
root = File.expand_path("../..", __dir__)
server_log = File.open(File.join(output, "server.log"), "w")
server = Process.spawn(environment, ENV.fetch("JULIA", "julia"), "--project=#{File.join(root, 'julia')}", File.join(root, "julia/server.jl"), database, options[:port].to_s,
  out: server_log, err: server_log)

def capture_json(*command)
  body, errors, status = Open3.capture3(*command)
  raise "#{File.basename(command.first)} failed: #{errors}" unless status.success?
  JSON.parse(body)
end

def query_database(database, query)
  capture_json("sqlite3", "-cmd", ".timeout 10000", "-readonly", "-json", database, query)
end

begin
  ready = false
  1200.times do
    raise "Julia exited before startup; inspect #{output}/server.log" if Process.waitpid(server, Process::WNOHANG)
    begin
      http = Net::HTTP.new("127.0.0.1", options[:port], nil)
      http.open_timeout = http.read_timeout = 1
      ready = http.get("/up").code == "200"
    rescue IOError, SystemCallError, Timeout::Error
    end
    break if ready
    sleep 0.1
  end
  raise "Julia did not start; inspect #{output}/server.log" unless ready
  login = capture_json(loadgen, "login", "--base", base, "--email", labels.fetch("emails.david"), "--password", labels.fetch("passwords.all"))
  cookie = login.fetch("cookie")
  room, write_room = labels.fetch("rooms.watercooler"), labels.fetch("rooms.hq")
  scrape = capture_json(loadgen, "scrape", "--base", base, "--cookie", cookie, "--room", room.to_s)
  prepared = BenchmarkContracts.prepare(base, cookie, database, labels, scrape.fetch("css"), File.join(output, "contracts"))
  routes = {
    "room_show" => "/rooms/#{room}",
    "messages_page" => "/rooms/#{room}/messages?before=#{labels.fetch('messages.busy_060')}",
    "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee",
    "avatar" => "/users/#{labels.fetch('avatar_tokens.jason')}/avatar",
    "static_css" => scrape.fetch("css"), "up" => "/up", "post_message" => nil
  }
  initial_count = query_database(database, "SELECT count(*) AS n FROM messages WHERE room_id=#{Integer(write_room)}").first.fetch("n")
  # The pinned Rails fixture contains one historical orphaned message. Preserve
  # that baseline while rejecting any new foreign-key violation from our writes.
  initial_foreign_keys = query_database(database, "SELECT * FROM pragma_foreign_key_check ORDER BY \"table\",rowid,parent,fkid")
  receipts, audits, acknowledged = [], [], 0
  routes.each do |name, path|
    [10, options[:requests]].each_with_index do |requests, iteration|
      phase = iteration.zero? ? "warmup" : "measured"
      arguments = [loadgen, "http", "--base", base, "--cookie", cookie,
        "--conc", options[:concurrency].to_s, "--requests", requests.to_s, "--duration", "30",
        "--validate", prepared.fetch(:contracts).fetch(name)]
      if path
        arguments += ["--path", path]
      else
        audit = File.join(output, "#{phase}-writes.jsonl")
        audits << audit
        arguments += ["--post-room", write_room.to_s, "--csrf", scrape.fetch("csrf").to_s, "--audit-writes", audit]
      end
      sample = capture_json(*arguments)
      checked, errors, status = Open3.capture3("ruby", File.join(verification, "bench/check_sample.rb"), stdin_data: JSON.generate(sample))
      raise "#{name} #{phase} failed upstream validation: #{errors}" unless status.success?
      receipt = JSON.parse(checked).merge("route" => name, "phase" => phase)
      File.write(File.join(output, "#{name}-#{phase}.json"), JSON.pretty_generate(receipt) + "\n")
      receipts << receipt
      acknowledged += receipt.fetch("ok") unless path
      puts "#{name} #{phase}: #{receipt.fetch('ok')} validated responses"
      $stdout.flush
    end
  end
  final_count = query_database(database, "SELECT count(*) AS n FROM messages WHERE room_id=#{Integer(write_room)}").first.fetch("n")
  raise "Acknowledged/persisted write count mismatch" unless final_count - initial_count == acknowledged
  audit = AcknowledgedWrites.verify(database, write_room, audits, acknowledged)
  raise "SQLite integrity check failed" unless query_database(database, "PRAGMA integrity_check").first.values == ["ok"]
  final_foreign_keys = query_database(database, "SELECT * FROM pragma_foreign_key_check ORDER BY \"table\",rowid,parent,fkid")
  raise "New SQLite foreign key violation" unless final_foreign_keys == initial_foreign_keys
  summary = { kind: "julia-upstream-conformance-v1", fixture: File.join(fixture, "source.json"),
    requests_per_route: options[:requests], concurrency: options[:concurrency],
    routes: routes.keys, preflight: prepared.fetch(:preflight), writes: audit,
    responses: receipts.sum { |receipt| receipt.fetch("ok") }, fixture_foreign_key_violations: initial_foreign_keys, results: receipts }
  File.write(File.join(output, "summary.json"), JSON.pretty_generate(summary) + "\n")
  puts "PASS: all 8 upstream route contracts, #{summary[:responses]} validated responses, #{acknowledged} audited writes. Receipts: #{output}"
ensure
  begin
    Process.kill("TERM", server)
    Process.wait(server)
  rescue Errno::ESRCH, Errno::ECHILD
  end
  server_log.close
end
