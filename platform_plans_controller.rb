module TeacherSection
  class PlatformPlansController < TeacherSectionController
    LIQPAY_FAIL_STATUSES = %w(failure error reversed).freeze
    LIQPAY_SUCCESS_STATUSES = Rails.application.config.liqpay_sandbox ? %w(success sandbox).freeze : %w(success).freeze

    protect_from_forgery except: :liqpay_callback

    def index
      respond_to :json
      if params[:we].present?
        render json: current_teacher.updating_platform_plans_info, status: 200
      else
        render json: { billing_plans: Admins::PlatformPlan.all.map(&:for_response) }, status: 200
      end
    end

    def pay_for_plan
      plan_payment_action
    end

    def change_plan
      plan_payment_action true
    end

    # route for Liqpay callback
    def liqpay_callback
      liqpay_response = Liqpay::Response.new(params)
      set_and_check_payment_from!(liqpay_response)
      if LIQPAY_SUCCESS_STATUSES.include?(liqpay_response.status)
        @payment.update_attributes(liqpay_transaction_id: liqpay_response.transaction_id,
                                   commissions: liqpay_response.commissions)
        @payment.complete!
      elsif LIQPAY_FAIL_STATUSES.include?(liqpay_response.status)
        @payment.fail!
      else
        logger.warn "Unknown liqpay response status: #{liqpay_response.status}, #{liqpay_response.to_s}"
      end
    rescue Liqpay::InvalidResponse
      logger.fatal "Incorrect liqpay response received: #{try(:liqpay_response)}"
    ensure
      head :ok
    end

    def liqpay_return
      @redirect_url = Teacher.find_by(id: params[:teacher_id])&.teacher_section_address
    end

    private

    def liqpay_payment_route_for(payment)
      request = Liqpay::Request.new(order_id: "#{payment.id}-#{payment.teacher_id}", amount: payment.amount,
                                    currency: payment.currency,
                                    server_url: teacher_section_liqpay_callback_url,
                                    result_url: teacher_section_liqpay_return_url(teacher_id: payment.teacher_id),
                                    description: payment.full_description)
      request.to_url
    end

    def set_and_check_payment_from!(liqpay_response)
      payment_id, teacher_id  = liqpay_response.order_id.try(:split, '-')
      @payment = Admins::PlatformPlanPayment.find_by(id: payment_id) if payment_id
      response_valid = teacher_id && @payment && @payment.teacher_id.to_s == teacher_id &&
        liqpay_response.amount == @payment.amount.to_f && liqpay_response.currency == @payment.currency
      unless response_valid
        logger.fatal 'Response did not pass validations'
        raise(Liqpay::InvalidResponse)
      end
    end

    def plan_payment_action(update_plan = false)
      platform_plan_payment = current_teacher.platform_plan_payments.new payment_params(current_teacher, update_plan)
      if platform_plan_payment.save
        redirect_to liqpay_payment_route_for(platform_plan_payment)
      else
        logger.error platform_plan_payment.errors.full_messages
        flash[:error] = I18n.t('errors.authorization')
        redirect_to root_path
      end
    end

    def payment_params(teacher, update_plan)
      if update_plan
        { platform_plan_id: params[:plan_id], months_amount: 0,
          old_platform_plan_id: teacher.platform_plan_id, is_changing_plan: true }
      else
        { platform_plan_id: params[:plan_id], months_amount: params[:months_amount] }
      end
    end
  end
end
