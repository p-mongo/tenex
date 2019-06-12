require 'tempfile'
require 'pathname'
require 'time'
autoload :FileUtils, 'fileutils'
require 'fe/child_process_helper'
require 'fe/mappings'

class RepoCache
  def initialize(owner, name)
    @owner, @name = owner, name
  end

  attr_reader :owner, :name

  def full_name
    "#{owner}/#{name}"
  end

  def repos_path
    Pathname.new(File.expand_path('~/.cache/repos'))
  end

  def cached_repo_path
    repos_path.join(name)
  end

  def update_cache
    @cache_updated ||= begin
      FileUtils.mkdir_p(repos_path)
      if File.exist?(cached_repo_path)
        Dir.chdir(cached_repo_path) do
          ChildProcessHelper.call(%w(git rebase --abort))
          ChildProcessHelper.check_call(%w(git reset --hard))
          ChildProcessHelper.check_call(%w(git checkout master))
          ChildProcessHelper.check_call(%w(git fetch origin))
          ChildProcessHelper.check_call(%w(git fetch p))
          ChildProcessHelper.check_call(%w(git reset --hard origin/master))
        end
      else
        ChildProcessHelper.check_call(%W(git clone git@github.com:#{full_name}) + [cached_repo_path.to_s])
        Dir.chdir(cached_repo_path) do
          ChildProcessHelper.check_call(%W(git remote add p git@github.com:p-mongo/#{name} -f))
        end
      end
      true
    end
    self
  end

  def add_remote(owner_name, repo_name)
    @remotes_updated ||= {}
    @remotes_updated["#{owner_name}/#{repo_name}"] ||= begin
      Dir.chdir(cached_repo_path) do
        begin
          ChildProcessHelper.check_call(%W(git remote rm #{owner_name}))
        rescue
        end
        ChildProcessHelper.check_call(%W(git remote add #{owner_name} https://github.com/#{owner_name}/#{repo_name} -f))
      end
    end
  end

  def master_sha
    update_cache

    Dir.chdir(cached_repo_path) do
      output = ChildProcessHelper.check_output(%w(git show --pretty=oneline))
      output.strip.split(/\s/, 2).first
    end
  end

  def my_remote_branches
    update_cache

    output = Dir.chdir(cached_repo_path) do
      ChildProcessHelper.check_output(%W(
        git branch -r
      ))
    end

    lines = output.split(/\n/).map(&:strip).select do |line|
      line !~ /->/ && line =~ /^p\//
    end

    lines.map do |line|
      line.sub(/.*\//, '')
    end
  end

  def recent_branches
    branches = my_remote_branches
    meta = {}
    branches.each do |branch|
      output = Dir.chdir(cached_repo_path) do
        ChildProcessHelper.check_output(%W(
          git show p/#{branch}
        ))
      end
      sha = output.split(/\s+/)[1]
      if output =~ /Date: \s+(.+)/
        date = $1
      else
        raise "No date"
      end
      meta[branch] = Time.parse(date)
    end

    branches.select! do |branch|
      Time.now - meta[branch] < 1.day
    end

    branches.sort_by do |branch|
      meta[branch]
    end.reverse

    branches
  end

  def commitish_time(commitish)
    output = Dir.chdir(cached_repo_path) do
      ChildProcessHelper.check_output(%W(
        git show #{commitish}
      ))
    end
    if output =~ /Date: \s+(.+)/
      date = $1
    else
      raise "No date"
    end
    Time.parse(date)
  end

  def commitish_message(commitish)
    output = Dir.chdir(cached_repo_path) do
      ChildProcessHelper.check_output(%W(
        git show -q #{commitish}
      ))
    end
    output.sub!(/\A.*\n.*\n.*\n\n/, '')
    output.gsub!(/^    /, '')
    output.split("\n\n", 2)
  end

  def diff_to_master(head)
    output = Dir.chdir(cached_repo_path) do
      ChildProcessHelper.check_output(%W(
        git diff master #{head}
      ))
    end
  end

  def rebase(pull)
    branch_name = pull.head_branch_name
    Dir.chdir(cached_repo_path) do
      ChildProcessHelper.check_call(['sh', '-c', <<-CMD])
        (git rebase --abort || true) &&
        git checkout master &&
        (git branch -D #{branch_name} || true) &&
        git checkout -b #{branch_name} --track p/#{branch_name} &&
        git rebase master &&
        git push -f
CMD
    end
  end

  def reword(pull, jirra_client)
    branch_name = pull.head_branch_name
    Dir.chdir(cached_repo_path) do
      project = Mappings.repo_path_to_jira_project(cached_repo_path)

      ticket = nil
      if branch_name =~ /#{project}-/i
        ticket = branch_name.upcase
      elsif branch_name =~ /^(\d+)($|-)/
        ticket = "#{project}-#{$1}"
      else
        ticket = pull.jira_ticket!
      end

      unless ticket
        raise "Could not figure out the ticket"
      end

      unless ticket =~ /^[A-Z]+-\d+$/
        raise "Weird ticket #{ticket} (project must be uppercased)"
      end

      subject = jirra_client.subject_for_issue(ticket)

      ChildProcessHelper.check_call(['sh', '-c', <<-CMD])
        git checkout master &&
        git pull &&
        if ! git remote |grep -qx p; then
          get remote add p git@github.com:p-mongo/#{name}
        fi &&
        git fetch p &&
        (git branch -D #{branch_name} || true) &&
        git checkout -b #{branch_name} --track p/#{branch_name} &&
        git reset --soft $(git merge-base master #{branch_name}) &&
        git commit -am "#{subject.gsub('"', "\\\"")}" &&
        git rebase master &&
        git push p #{branch_name} -f
CMD
    end
  end

  def set_commit_message(pull, message)
    Tempfile.create do |tempfile|
      tempfile << message
      tempfile.flush

      branch_name = pull.head_branch_name
      Dir.chdir(cached_repo_path) do

        ChildProcessHelper.check_call(['sh', '-c', <<-CMD])
          git checkout master &&
          git pull &&
          if ! git remote |grep -qx p; then
            get remote add p git@github.com:p-mongo/#{name}
          fi &&
          git fetch p &&
          (git branch -D #{branch_name} || true) &&
          git checkout -b #{branch_name} --track p/#{branch_name} &&
          git commit --amend -F "#{tempfile.path}" &&
          git push p #{branch_name} -f
CMD
      end
    end
  end

  def recent_branches(limit, extra=nil)
    Dir.chdir(cached_repo_path) do
      output = ChildProcessHelper.check_output(['sh', '-c', <<-CMD])
        git branch --sort=-committerdate #{extra}
CMD
      branches = output.split("\n").map do |branch|
        if branch =~ /\s+master$/
          nil
        else
          branch.strip
        end
      end.compact
    end
  end

  def recent_remote_branches(limit)
    branches = recent_branches(limit, '-r')
    branches.map do |branch|
      if branch =~ %r,^p/,
        branch.sub(%r,^p/,, '')
      else
        nil
      end
    end.compact
  end
end
