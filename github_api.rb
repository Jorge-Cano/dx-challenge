#!/usr/bin/env ruby
# frozen_string_literal: true

# github_api.rb
#
# Fetches a merged pull request from the GitHub API and writes a CSV with:
#   (a) author details (GitHub user profile)
#   (b) merger details (GitHub user profile)
#   (c) PR details: additions, deletions, created_at, merged_at, time to merge
#
# Usage:
#   ruby github_api.rb OWNER REPO PR_NUMBER [OUTPUT_FILE]
#
# Example:
#   ruby github_api.rb octocat Hello-World 1347 pr_1347.csv
#
# Authentication (optional but recommended to avoid rate limits):
#   export GITHUB_TOKEN=ghp_your_token_here

require 'net/http'
require 'json'
require 'csv'
require 'time'
require 'uri'

class GitHubApi
  BASE_URL = 'https://api.github.com'

  class Error < StandardError; end

  def initialize(token = ENV['GITHUB_TOKEN'])
    @token = token
  end

  def pull_request(owner, repo, number)
    get("/repos/#{owner}/#{repo}/pulls/#{number}")
  end

  def user(login)
    get("/users/#{login}")
  end

  private

  def get(path)
    uri = URI("#{BASE_URL}#{path}")
    request = Net::HTTP::Get.new(uri)
    request['Accept'] = 'application/vnd.github+json'
    request['X-GitHub-Api-Version'] = '2022-11-28'
    request['User-Agent'] = 'github_api.rb'
    request['Authorization'] = "Bearer #{@token}" if @token && !@token.empty?

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
      http.request(request)
    end

    handle_response(response, path)
  end

  def handle_response(response, path)
    case response
    when Net::HTTPSuccess
      JSON.parse(response.body)
    when Net::HTTPNotFound
      raise Error, "Not found: #{path} (check owner, repo, and PR number; private repos need a token)"
    when Net::HTTPUnauthorized
      raise Error, 'Unauthorized: your GITHUB_TOKEN is invalid or expired'
    when Net::HTTPForbidden, Net::HTTPTooManyRequests
      remaining = response['x-ratelimit-remaining']
      reset = response['x-ratelimit-reset']
      if remaining == '0' && reset
        raise Error, "Rate limit exceeded. Resets at #{Time.at(reset.to_i).utc.iso8601}. " \
                     'Set GITHUB_TOKEN to raise your limit.'
      end
      raise Error, "Forbidden (HTTP #{response.code}): #{response.body}"
    else
      raise Error, "GitHub API error (HTTP #{response.code}): #{response.body}"
    end
  end
end

# Turns a number of seconds into a readable string like "2d 3h 15m 10s".
def humanize_duration(total_seconds)
  total_seconds = total_seconds.to_i
  days, rem = total_seconds.divmod(86_400)
  hours, rem = rem.divmod(3_600)
  minutes, seconds = rem.divmod(60)

  parts = []
  parts << "#{days}d" if days.positive?
  parts << "#{hours}h" if hours.positive?
  parts << "#{minutes}m" if minutes.positive?
  parts << "#{seconds}s" if seconds.positive? || parts.empty?
  parts.join(' ')
end

# Builds a hash of user fields with a column prefix, e.g. "author_login".
def user_columns(prefix, user)
  {
    "#{prefix}_login" => user['login'],
    "#{prefix}_id" => user['id'],
    "#{prefix}_name" => user['name'],
    "#{prefix}_email" => user['email'],
    "#{prefix}_company" => user['company'],
    "#{prefix}_location" => user['location'],
    "#{prefix}_bio" => user['bio'],
    "#{prefix}_public_repos" => user['public_repos'],
    "#{prefix}_followers" => user['followers'],
    "#{prefix}_following" => user['following'],
    "#{prefix}_account_created_at" => user['created_at'],
    "#{prefix}_profile_url" => user['html_url']
  }
end

def build_row(pr, author, merger)
  created_at = Time.parse(pr['created_at'])
  merged_at = Time.parse(pr['merged_at'])
  seconds_to_merge = (merged_at - created_at).to_i

  row = {}
  row.merge!(user_columns('author', author))
  row.merge!(user_columns('merger', merger))
  row.merge!(
    'pr_number' => pr['number'],
    'pr_title' => pr['title'],
    'pr_url' => pr['html_url'],
    'pr_additions' => pr['additions'],
    'pr_deletions' => pr['deletions'],
    'pr_created_at' => pr['created_at'],
    'pr_merged_at' => pr['merged_at'],
    'pr_time_to_merge_seconds' => seconds_to_merge,
    'pr_time_to_merge' => humanize_duration(seconds_to_merge)
  )
  row
end

def write_csv(row, path)
  CSV.open(path, 'w', write_headers: true, headers: row.keys) do |csv|
    csv << row.values
  end
end

def main
  if ARGV.length < 3
    warn 'Usage: ruby github_api.rb OWNER REPO PR_NUMBER [OUTPUT_FILE]'
    exit 1
  end

  owner, repo, number = ARGV[0], ARGV[1], ARGV[2]
  output = ARGV[3] || "pr_#{number}.csv"

  unless number.match?(/\A\d+\z/)
    warn "PR_NUMBER must be a positive integer (got '#{number}')"
    exit 1
  end

  api = GitHubApi.new

  pr = api.pull_request(owner, repo, number)

  unless pr['merged'] && pr['merged_at']
    warn "PR ##{number} has not been merged (state: #{pr['state']}). Choose a merged PR."
    exit 1
  end

  author_login = pr.dig('user', 'login')
  # In this exercise the merger is the same as the author, but we read
  # merged_by from the API and fall back to the author if it is missing.
  merger_login = pr.dig('merged_by', 'login') || author_login

  author = api.user(author_login)
  merger = merger_login == author_login ? author : api.user(merger_login)

  row = build_row(pr, author, merger)
  write_csv(row, output)

  puts "Wrote #{output}"
  puts "PR ##{pr['number']}: +#{pr['additions']} / -#{pr['deletions']}, " \
       "merged in #{row['pr_time_to_merge']}"
rescue GitHubApi::Error => e
  warn "Error: #{e.message}"
  exit 1
rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout => e
  warn "Network error: #{e.message}"
  exit 1
end

main if $PROGRAM_NAME == __FILE__
