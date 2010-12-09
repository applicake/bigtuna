class Build < ActiveRecord::Base
  STATUS_IN_QUEUE = "status_build_in_queue"
  STATUS_PROGRESS = "status_build_in_progress"
  STATUS_OK = "status_build_ok"
  STATUS_FAILED = "status_build_failed"
  STATUS_BUILDER_ERROR = "status_builder_error"
  STATUS_HOOK_ERROR = "status_hook_error"

  belongs_to :project
  has_many :parts, :class_name => "BuildPart"

  before_destroy :remove_build_dir
  before_create :set_build_values
  serialize :output, Array

  def perform
    self.update_attributes!(:status => STATUS_PROGRESS)
    self.started_at = Time.now
    project = self.project
    begin
      out = project.vcs.clone(self.build_dir)
      self.update_attributes!(vcs.head_info[0].merge(:output => [out]))
      vcs_ok = true
    rescue BigTuna::Runner::Error => e
      self.status = STATUS_FAILED
      self.output = [e.output]
      self.save!
      vcs_ok = false
    end
    run_build_parts() if vcs_ok
  end

  def display_name
    "Build ##{self.build_no} @ #{I18n.l(self.scheduled_at, :format => :long)}"
  end

  def to_param
    [self.id, self.project.name.to_url, self.display_name.to_url].join("-")
  end

  def started?
    ! started_at.nil?
  end

  def commit_data?
    self.author && self.email && self.commit_message && self.committed_at && self.commit
  end

  def finished?
    ! finished_at.nil?
  end

  def vcs
    return @vcs if @vcs
    vcs_type = self.project.vcs_type
    vcs_branch = self.project.vcs_branch
    klass = BigTuna.vcses.find { |e| e::VALUE == vcs_type }
    raise ArgumentError.new("VCS not supported: %p" % [vcs_type]) if klass.nil?
    @vcs = klass.new(self.build_dir, vcs_branch)
  end

  def update_part(part)
    if parts.where(:finished_at => nil).count == 0 # build finished
      statuses = parts.map { |p| p.status }
      status = statuses.all? { |e| e == BuildPart::STATUS_OK } ? STATUS_OK : STATUS_FAILED
      self.update_attributes!(:finished_at => Time.now, :status => status)
      if status != STATUS_OK
        new_failed_builds = project.failed_builds + 1
        project.update_attributes!(:failed_builds => new_failed_builds)
        after_failed()
      else
        after_passed()
      end
      after_finished()
    end
    project.truncate_builds!
  end

  private
  def remove_build_dir
    if File.directory?(self.build_dir)
      FileUtils.rm_rf(self.build_dir)
    else
      BigTuna.logger.info("Couldn't find build dir to remove: %p" % [self.build_dir])
    end
  end

  def set_build_values
    project_dir = project.build_dir
    self.build_dir = File.join(project_dir, "build_#{self.build_no}_#{self.scheduled_at.strftime("%Y%m%d%H%M%S")}")
    self.status = STATUS_IN_QUEUE
    self.scheduled_at = Time.now
    self.output = []
  end

  def run_build_parts
    statuses = []
    self.project.step_lists.each do |step_list|
      attrs = {
        :name => step_list.name,
        :steps => step_list.steps,
      }
      part = self.parts.build(attrs)
      part.save!
      part.build!
    end
  end

  def after_passed
    previous_build = self.project.builds.order("created_at DESC").offset(1).first
    build_fixed = (status == STATUS_OK && previous_build && previous_build.status == STATUS_FAILED)
    build_still_passes = (status == STATUS_OK && previous_build && previous_build.status == STATUS_OK)
    project.hooks.each do |hook|
      hook.build_passed(self)
      hook.build_still_passes(self) if build_still_passes
      hook.build_fixed(self) if build_fixed
    end
  end

  def after_failed
    previous_build = self.project.builds.order("created_at DESC").offset(1).first
    build_failed = (previous_build.nil? or (previous_build && previous_build.status == STATUS_OK))
    build_still_fails = (previous_build and previous_build.status != STATUS_OK)
    project.hooks.each do |hook|
      hook.build_failed(self) if build_failed
      hook.build_still_fails(self) if build_still_fails
    end
  end

  def after_finished
    previous_build = self.project.builds.order("created_at DESC").offset(1).first
    project.hooks.each do |hook|
      hook.build_finished(self)
    end
  end
end
