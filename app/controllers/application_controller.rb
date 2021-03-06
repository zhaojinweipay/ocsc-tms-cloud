class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception
  skip_before_action :verify_authenticity_token
  include ApplicationHelper
  include SessionsHelper

  before_action :authenticate_user
end
