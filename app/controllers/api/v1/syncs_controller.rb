class Api::V1::SyncsController < ApplicationController
  skip_before_action :authenticate_user
  before_action :set_params, only: [:create]

  def index
    if all_models.include? params[:model_name]
      render json: params[:model_name].constantize.from_exact_branch("master")
    else
      render json: {error: "Model does not exist"}
    end
  end

  def create
    @params = @params.to_h
    for i in 0...@params[:sync_in].count
      sync_in = @params[:sync_in][@params[:cron_sync] ? i : "#{i}"]
      model = sync_in[:model_name].constantize

      if sync_in[:records]
        for j in 0...sync_in[:records].count
          record = sync_in[:records][@params[:cron_sync] ? j : "#{j}"]
          if model.find_by id: record[:id]
            existing_record = model.find_by id: record[:id]
            if existing_record.updated_at < record[:updated_at].to_datetime
              existing_record.update record
              unless existing_record.save
                render json: {model: sync_in[:model_name], status: "ERROR"}
              end
            end
          else
            model_param = {}
            record.keys.each do |key|
              model_param[key] = record[@params[:cron_sync] ? key : "#{key}"]
            end
            model_param[:branch] = [@params[:branch]] unless !@params[:branch]
            model_param[:id_from_branch] = [record[:id]]
            unless model.create(model_param)
              render json: {model: sync_in[:model_name], status: "ERROR"}
            end
          end
        end
      end
    end
    render json: {model: "all", status: "OK"}
  end

  private
  def set_params
    @params = params.require(:sync).permit!
  end

  def new_record?(record)
    record[:created_at] === record[:updated_at]
  end

  def all_models
    files = Dir[Rails.root + 'app/models/*.rb']
    files.map{ |m| File.basename(m, '.rb').camelize }
  end
end
