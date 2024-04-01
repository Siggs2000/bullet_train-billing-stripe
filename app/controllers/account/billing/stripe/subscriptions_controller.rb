class Account::Billing::Stripe::SubscriptionsController < Account::ApplicationController
  account_load_and_authorize_resource :subscription, through: :team, through_association: :billing_stripe_subscriptions, member_actions: [:checkout, :refresh, :portal]

  # GET/POST /account/billing/stripe/subscriptions/:id/checkout
  # GET/POST /account/billing/stripe/subscriptions/:id/checkout.json
  def checkout
    trial_days = @subscription.generic_subscription.included_prices.map { |ip| ip.price.trial_days }.compact.max
    allow_promotion_codes = @subscription.generic_subscription.included_prices.map { |ip| ip.price.allow_promotion_codes }.compact.any?

    session_attributes = {
      payment_method_types: ["card"],
      subscription_data: {
        items: @subscription.stripe_items,
        trial_settings: {end_behavior: {missing_payment_method: 'cancel'}},
      }.merge(trial_days ? {trial_period_days: trial_days} : {}),
      customer: @team.stripe_customer_id,
      client_reference_id: @subscription.id,
      success_url: CGI.unescape(url_for([:refresh, :account, @subscription, session_id: "{CHECKOUT_SESSION_ID}"])),
      cancel_url: url_for([:account, @subscription.generic_subscription]),
      metadata: {
        promotekit_referral: req.body.referral,
      },
      allow_promotion_codes: allow_promotion_codes,
      payment_method_collection: 'if_required',
    }

    unless @team.stripe_customer_id
      session_attributes[:customer_email] = current_membership.email
    end

    # Stripe requires that Checkout Sessions having different attributes must
    # have different idempotency keys, so include the updated_at in the key.
    idempotency_key = "#{t("application.name")}:subscription:#{@subscription.id}:#{@subscription.updated_at.to_i}"

    session = Stripe::Checkout::Session.create(session_attributes, idempotency_key: idempotency_key)

    redirect_to session.url, allow_other_host: true
  end

  # POST /account/billing/stripe/subscriptions/:id/portal
  # POST /account/billing/stripe/subscriptions/:id/portal.json
  def portal
    session = Stripe::BillingPortal::Session.create({
      customer: @team.stripe_customer_id,
      return_url: url_for([:account, @subscription.generic_subscription])
    })

    redirect_to session.url, allow_other_host: true
  end

  # GET /account/billing/stripe/subscriptions/:id/refresh
  # GET /account/billing/stripe/subscriptions/:id/refresh.json
  def refresh
    # If the checkout session is paid already, we want to do a couple things quickly without waiting for a webhook.
    checkout_session = Stripe::Checkout::Session.retrieve(params[:session_id])
    @subscription.refresh_from_checkout_session(checkout_session)

    redirect_to [:account, @subscription.generic_subscription.team], notice: t("billing/stripe/subscriptions.notifications.refreshed")
  end
end
