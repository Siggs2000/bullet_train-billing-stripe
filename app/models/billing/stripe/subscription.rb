class Billing::Stripe::Subscription < ApplicationRecord
  belongs_to :team
  has_one :generic_subscription, class_name: "Billing::Subscription", as: :provider_subscription

  def stripe_items
    generic_subscription.included_prices.map do |included_price|
      {
        plan: Billing::Stripe::PriceAdapter.new(included_price.price).stripe_price_id,
        quantity: included_price.quantity,
      }
    end
  end

  def refresh_from_checkout_session(stripe_checkout_session)
    # If the checkout is already marked as paid, we want to shortcut a few things instead of waiting for the webhook.
    if stripe_checkout_session.payment_status == "paid"
      # We need the full-blown subscription object for the end of cycle timing.
      stripe_subscription = Stripe::Subscription.retrieve(stripe_checkout_session.subscription)
      update(stripe_subscription_id: stripe_checkout_session.subscription)
      generic_subscription.update(status: :active, cycle_ends_at: Time.at(stripe_subscription.current_period_end))
      team.update(stripe_customer_id: stripe_checkout_session.customer)
    end
  end

  def update_included_prices(subscription_items)
    remaining_included_price_ids = []

    subscription_items.each do |subscription_item|
      stripe_price_id = subscription_item.dig("price", "id")

      # See if we're already including a matching price locally.
      price = Billing::Stripe::PriceAdapter.find_by_stripe_price_id(stripe_price_id)
      included_price = generic_subscription.included_prices.find_or_create_by(price_id: price.id) do |ip|
        ip.quantity = subscription_item.dig("quantity")
      end

      remaining_included_price_ids << included_price.id
    end

    # Clean up any old prices that were on file but are no longer on the Stripe subscription.
    generic_subscription.included_prices.where.not(id: remaining_included_price_ids).destroy_all
  end
end
