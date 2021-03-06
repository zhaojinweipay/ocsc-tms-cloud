class PaymentsController < ApplicationController
  include DocumentsHelper
  include SmartListing::Helper::ControllerExtensions
  helper SmartListing::Helper
  before_action :auth_user_type

  before_action :set_params, only: [:create, :create_multiple]

  before_action :get_inital_report, only: [:cargo_collect_report, :cargo_transaction_report]

  def daily_report
  end

  def create
    document = Document.find(@params[:document_id])
    if document.status1 === 2
      redirect_to "/payments/#{document.id}" 
    else
      @payment = Payment.new @params
      @payment.id = generate_id("MSTR-PAY",Payment)

      total_amount = document.total_amount
      paid = document.payments.where(payments: {status: 1}).sum(:amount)
      if @payment.amount > (total_amount - paid)
        @payment.amount = (total_amount - paid)
      end

      if @payment.save 
        total_amount = document.total_amount
        paid = document.payments.where(payments: {status: 1}).sum(:amount)
        if (total_amount - paid === 0)
          document.update_attribute(:status1, 2) 
        else
          document.update_attribute(:status1, 1) 
        end
        redirect_to "/payments/#{@payment.document_id}"
      else
        redirect_to action: "add", id: @payment.document_id
      end
    end
  end

  def create_multiple
    client = Client.find @params[:client][:id]
    amount_due = @params[:documents].reduce(0) { |sum, element| sum + element[:balance].to_f }
    payment = @params[:amount].to_f + client.over_payment.to_f

    @params[:documents].each do |doc|
      document = Document.find_by id: doc[:id]
      each_payment = Payment.new do |p|
        p.id = generate_id("MSTR-PAY",Payment)
        p.document_id = doc[:id]
        p.amount = doc[:balance]
        p.ref_id = @params[:ref_id]
        p.trans_date = @params[:trans_date]
        p.description = @params[:description]
        p.deposit_date = @params[:deposit_date]
        p.employee_id = @params[:employee_id] if @params[:employee_id] != "none"
      end
      if each_payment.save
        total_amount = document.total_amount
        paid = document.payments.where(payments: {status: 1}).sum(:amount)
        if (total_amount - paid === 0)
          document.update_attribute(:status1, 2) 
        else
          document.update_attribute(:status1, 1) 
        end
      end
    end

    client.over_payment = (amount_due - payment).abs
    if client.save
      render json: {status: "OK"}
    else
      render json: {status: "error"}
    end
  end

  def add
    @doc = Document.includes(:payments).find(params[:id])
    redirect_to "/payments/#{@doc.id}" if @doc.status1 === 2
    @payment = Payment.new
    @paid = @doc.payments.where(payments: {status: 1}).sum(:amount)
  end

  def show
    @doc = Document.includes(:payments).find(params[:id])
    @payments = @doc.payments.where(payments: {status: 1})
    @paid = @doc.payments.where(payments: {status: 1}).sum(:amount)
  end

  def destroy
    @payment = Payment.find(params[:id])
    document_id = @payment.document_id
    @payment.update_attribute :status, 0
    document = Document.find(document_id)
    total_amount = document.total_amount
    paid = document.payments.where(payments: {status: 1}).sum(:amount)
    if (total_amount - paid === 0)
      document.update_attribute(:status1, 2) 
    else
      document.update_attribute(:status1, 1) 
    end
    redirect_to "/payments/#{document_id}"
  end

  def collection
    collection_scope = Document.includes(:payments).cargo.not_cancelled
    # collection_scope = collection_scope.search(params[:filter]) if params[:filter]
    @collection = smart_listing_create(
      :collections,
      collection_scope,
      partial: "collections/list",
      default_sort: {updated_at: "desc"}
    )
  end

  def soa
    @clients = Client.active.premium
  end

  def soa_print
		month = params[:f_month]
		year = params[:f_year]
		client_id = params[:f_client]
    @client = Client.find_by id: client_id

    client_cargo = @client.documents.includes(:payments).cargo.not_cancelled

    @cargo_this_month = client_cargo
    .where(payments: {payment_type: nil})
    .or(client_cargo.where(payments: {payment_type: "collect"}))
    .where("extract(year from documents.trans_date) = #{year}")
    .where("extract(month from documents.trans_date) = #{month}")
    .where.not(status1: 2)
    #
    # query = "MONTH(documents.trans_date) = ? AND YEAR(documents.trans_date) = ?"
    month_year = client_cargo.map { |m| [m.trans_date.month, m.trans_date.year] }.uniq
    @cargo_per_month = month_year.map do |my| 
      cargo = @client.documents.cargo.not_cancelled
      cargo_per_month = cargo
      .where("extract(month from documents.trans_date) = #{my[0]}")
      .where("extract(year from documents.trans_date) = #{my[1]}")
      .where.not(documents: {status1: 2})

      amount = cargo_per_month.sum(:total_amount) 

      {
        date: "#{Date::MONTHNAMES[my[0]]} #{my[1]}",
        amount: amount
      }
    end

    @payments = @client.payments
    .includes(:document)
    .where.not(documents: {status1: 2})
    .where.not(payments: {status: 0})
    #
    # query = "MONTH(payments.trans_date) = ? AND YEAR(payments.trans_date) = ?"
    # payment_per_month = client_cargo.where.not(documents: {status1: 0}, payments: {status: 0}).includes(:payments)
    # month_year = payment_per_month.map { |m| [m.trans_date.month, m.trans_date.year] }.uniq
    # @payment_per_month = month_year.map do |my| 
    #   {
    #     date: "#{Date::MONTHNAMES[my[0]]} #{my[1]}",
    #     amount: payment_per_month.where(query, my[0], my[1]).sum(:amount)
    #   }
    # end
  end

  def cargo_collect_report
    @date = params[:date]
    @report = @initial_report
    .cargo
    .where(payments: {payment_type: nil})
    .or(@initial_report.where(payments: {payment_type: "collect"}))
  end

  def cargo_transaction_report
    @date = params[:date]
    @report_totals = {collect: 0, cash: 0, remittance: 0, total: 0, qty: 0}
    @report = @initial_report.cargo.map do |waybill|
      payment_mode = payment_mode waybill.id
      if waybill.status1 === 0
        amount = 0.00
        cash = 0.00
        collect = 0.00
        qty = 0
      else
        amount = waybill.total_amount
        cash = (payment_mode === "cash" ? amount : 0.00)
        collect = (payment_mode === "collect" ? amount : 0.00)
        qty = waybill.document_details.sum(:qty)
      end
      {
        cwb: "#{remove_cwb_waybill_batch_prefix waybill.ref_id}",
        tags: format_document_tags(waybill.document_tags.ids),
        qty: qty,
        cash: cash,
        collect: collect,
        total: amount,
        remittance: cash,
        deleted: waybill.status1 === 0
      }
    end
  end

  private

  def get_inital_report
    @initial_report = Document.includes(
      :client,
      :document_details,
      :payments
    ).from_exact_branch(session[:branch])
    .where(documents: {trans_date: params[:date]})
  end

  def set_params
    @params = params.require(:payment).permit!
  end

end
