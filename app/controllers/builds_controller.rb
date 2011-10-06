class BuildsController < ApplicationController
  before_filter :locate_build, :only => [:show, :destroy]
  respond_to :js, :only => :show

  def show
    respond_to do |format|
      format.html
      format.json { render :json => @build.to_json }
    end
  end

  def destroy
    project = @build.project
    @build.destroy
    redirect_to project_path(project)
  end

  private
  def locate_build
    @build = Build.find(params[:id])
  end
end
