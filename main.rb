# frozen_string_literal: true

require 'cask'
require 'utils/pypi'

class Object
  def false?
    nil?
  end
end

class String
  def false?
    empty? || strip == 'false'
  end
end

module Homebrew
  module_function

  def print_command(*cmd)
    puts "[command]#{cmd.join(' ').gsub("\n", ' ')}"
  end

  def brew(*args)
    print_command ENV["HOMEBREW_BREW_FILE"], *args
    safe_system ENV["HOMEBREW_BREW_FILE"], *args
  end

  def git(*args)
    print_command ENV["HOMEBREW_GIT"], *args
    safe_system ENV["HOMEBREW_GIT"], *args
  end

  def read_brew(*args)
    print_command ENV["HOMEBREW_BREW_FILE"], *args
    output = `#{ENV["HOMEBREW_BREW_FILE"]} #{args.join(' ')}`.chomp
    odie output if $CHILD_STATUS.exitstatus != 0
    output
  end

  # Get inputs
  message = ENV['HOMEBREW_BUMP_MESSAGE']
  org = ENV['HOMEBREW_BUMP_ORG']
  tap = ENV['HOMEBREW_BUMP_TAP']
  cask = ENV['HOMEBREW_BUMP_CASK']
  tag = ENV['HOMEBREW_BUMP_TAG']
  revision = ENV['HOMEBREW_BUMP_REVISION']
  force = ENV['HOMEBREW_BUMP_FORCE']
  livecheck = ENV['HOMEBREW_BUMP_LIVECHECK']

  # Check inputs
  if livecheck.false?
    odie "Need 'cask' input specified" if cask.blank?
    odie "Need 'tag' input specified" if tag.blank?
  end

  # Get user details
  user = GitHub::API.open_rest "#{GitHub::API_URL}/user"
  user_id = user['id']
  user_login = user['login']
  user_name = user['name'] || user['login']
  user_email = user['email'] || (
    # https://help.github.com/en/github/setting-up-and-managing-your-github-user-account/setting-your-commit-email-address
    user_created_at = Date.parse user['created_at']
    plus_after_date = Date.parse '2017-07-18'
    need_plus_email = (user_created_at - plus_after_date).positive?
    user_email = "#{user_login}@users.noreply.github.com"
    user_email = "#{user_id}+#{user_email}" if need_plus_email
    user_email
  )

  # Tell git who you are
  git 'config', '--global', 'user.name', user_name
  git 'config', '--global', 'user.email', user_email

  # Tap the tap if desired
  brew 'tap', tap unless tap.blank?

  # Append additional PR message
  message = if message.blank?
              ''
            else
              message + "\n\n"
            end
  message += '[`action-homebrew-bump-cask`](https://github.com/macauley/action-homebrew-bump-cask)'

  # Do the livecheck stuff or not
  if livecheck.false?
    # Change cask name to full name
    cask = tap + '/' + cask if !tap.blank? && !cask.blank?

    # Get info about cask
    # FIXME
    stable = cask[cask].stable
    is_git = stable.downloader.is_a? GitDownloadStrategy

    # Prepare tag and url
    tag = tag.delete_prefix 'refs/tags/'
    version = Version.parse tag
    url = stable.url.gsub stable.version, version

    # Check if cask is originating from PyPi
    pypi_url = PyPI.update_pypi_url(stable.url, version)
    if pypi_url
      # Substitute url
      url = pypi_url
      # Install pipgrip utility so resources from PyPi get updated too
      brew 'install', 'pipgrip'
    end

    # Finally bump the cask
    brew 'bump-cask-pr',
         '--no-audit',
         '--no-browse',
         "--message=#{message}",
         *("--fork-org=#{org}" unless org.blank?),
         *("--version=#{version}" unless is_git),
         *("--url=#{url}" unless is_git),
         *("--tag=#{tag}" if is_git),
         *("--revision=#{revision}" if is_git),
         *('--force' unless force.false?),
         cask
  else
    # Support multiple casks in input and change to full names if tap
    unless cask.blank?
      cask = cask.split(/[ ,\n]/).reject(&:blank?)
      cask = cask.map { |f| tap + '/' + f } unless tap.blank?
    end

    # Get livecheck info
    json = read_brew 'livecheck',
                     '--cask',
                     '--quiet',
                     '--newer-only',
                     '--full-name',
                     '--json',
                     *("--tap=#{tap}" if !tap.blank? && cask.blank?),
                     *(cask unless cask.blank?)
    json = JSON.parse json

    # Define error
    err = nil

    # Loop over livecheck info
    json.each do |info|
      # Skip if there is no version field
      next unless info['version']

      # Get info about cask
      cask = info['cask']
      version = info['version']['latest']

      # Get stable software spec of the cask
      stable = cask[cask].stable

      # Check if cask is originating from PyPi
      if !cask["pipgrip"].any_version_installed? && PyPI.update_pypi_url(stable.url, version)
        # Install pipgrip utility so resources from PyPi get updated too
        brew 'install', 'pipgrip'
      end

      begin
        # Finally bump the cask
        brew 'bump-cask-pr',
             '--no-audit',
             '--no-browse',
             "--message=#{message}",
             "--version=#{version}",
             *("--fork-org=#{org}" unless org.blank?),
             *('--force' unless force.false?),
             cask
      rescue ErrorDuringExecution => e
        # Continue execution on error, but save the exeception
        err = e
      end
    end

    # Die if error occured
    odie err if err
  end
end
