require_relative "../../ecommerce/ordering/lib/ordering"
require_relative "../../ecommerce/pricing/lib/pricing"
require_relative "../../ecommerce/product_catalog/lib/product_catalog"
require_relative "../../ecommerce/crm/lib/crm"
require_relative "../../ecommerce/payments/lib/payments"
require_relative "../../ecommerce/inventory/lib/inventory"
require_relative "../../ecommerce/shipping/lib/shipping"
require_relative "customer_repository"
require_relative "product_repository"

module Ecommerce
  class Configuration
    def call(cqrs)
      enable_res_infra_event_linking(cqrs)

      enable_orders_read_model(cqrs)
      enable_products_read_model(cqrs)
      enable_customers_read_model(cqrs)

      configure_bounded_contexts(cqrs, Rails.configuration.number_generator, Rails.configuration.payment_gateway)

      enable_release_payment_process(cqrs)
      enable_order_confirmation_process(cqrs)
      enable_pricing_sync_from_ordering(cqrs)
      calculate_total_value_when_order_submitted(cqrs)
      notify_payments_about_order_total_value(cqrs)
      enable_inventory_sync_from_ordering(cqrs)
      enable_shipment_sync(cqrs)
      enable_shipment_process(cqrs)
      check_product_availability_on_adding_item_to_basket(cqrs)
    end

    def enable_res_infra_event_linking(cqrs)
      [
        RailsEventStore::LinkByEventType.new,
        RailsEventStore::LinkByCorrelationId.new,
        RailsEventStore::LinkByCausationId.new
      ].each { |h| cqrs.subscribe_to_all_events(h) }
    end

    def enable_products_read_model(cqrs)
      Products::Configuration.new.call(cqrs)
    end

    def enable_customers_read_model(cqrs)
      Customers::Configuration.new.call(cqrs)
    end

    def enable_orders_read_model(cqrs)
      Orders::Configuration.new(product_repository, customer_repository).call(cqrs)
    end

    def enable_shipment_process(cqrs)
      cqrs.subscribe(
        ShipmentProcess.new,
        [
          Shipping::ShippingAddressAddedToShipment,
          Shipping::ShipmentSubmitted,
          Ordering::OrderSubmitted,
          Ordering::OrderPaid
        ]
      )
    end

    def enable_shipment_sync(cqrs)
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Shipping::AddItemToShipmentPickingList.new(
              order_id: event.data.fetch(:order_id),
              product_id: event.data.fetch(:product_id)
            )
          )
        end,
        [Ordering::ItemAddedToBasket]
      )
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Shipping::RemoveItemFromShipmentPickingList.new(
              order_id: event.data.fetch(:order_id),
              product_id: event.data.fetch(:product_id)
            )
          )
        end,
        [Ordering::ItemRemovedFromBasket]
      )
    end

    def notify_payments_about_order_total_value(cqrs)
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Payments::SetPaymentAmount.new(
              order_id: event.data.fetch(:order_id),
              amount: event.data.fetch(:discounted_amount).to_f
            )
          )
        end,
        [Pricing::OrderTotalValueCalculated]
      )
    end

    def calculate_total_value_when_order_submitted(cqrs)
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Pricing::CalculateTotalValue.new(
              order_id: event.data.fetch(:order_id)
            )
          )
        end,
        [Ordering::OrderSubmitted]
      )
    end

    def enable_inventory_sync_from_ordering(cqrs)
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Inventory::SubmitReservation.new(
              order_id: event.data.fetch(:order_id),
              reservation_items: event.data.fetch(:order_lines)
            )
          )
        end,
        [Ordering::OrderSubmitted]
      )

      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Inventory::CompleteReservation.new(
              order_id: event.data.fetch(:order_id)
            )
          )
        end,
        [Ordering::OrderPaid]
      )

      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Inventory::CancelReservation.new(
              order_id: event.data.fetch(:order_id)
            )
          )
        end,
        [Ordering::OrderCancelled, Ordering::OrderExpired]
      )
    end

    def enable_pricing_sync_from_ordering(cqrs)
      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Pricing::AddPriceItem.new(
              order_id: event.data.fetch(:order_id),
              product_id: event.data.fetch(:product_id)
            )
          )
        end,
        [Ordering::ItemAddedToBasket]
      )

      cqrs.subscribe(
        ->(event) do
          cqrs.run(
            Pricing::RemovePriceItem.new(
              order_id: event.data.fetch(:order_id),
              product_id: event.data.fetch(:product_id)
            )
          )
        end,
        [Ordering::ItemRemovedFromBasket]
      )
    end

    def enable_order_confirmation_process(cqrs)
      cqrs.subscribe(
        OrderConfirmation.new,
        [Payments::PaymentAuthorized, Payments::PaymentCaptured]
      )
    end

    def enable_release_payment_process(cqrs)
      cqrs.subscribe(
        ReleasePaymentProcess.new,
        [
          Ordering::OrderSubmitted,
          Ordering::OrderExpired,
          Ordering::OrderPaid,
          Payments::PaymentAuthorized,
          Payments::PaymentReleased
        ]
      )
    end

    def check_product_availability_on_adding_item_to_basket(cqrs)
      cqrs.subscribe(
        Inventory::CheckAvailabilityOnOrderItemAddedToBasket.new(cqrs.event_store),
        [Ordering::ItemAddedToBasket]
      )
    end

    def configure_bounded_contexts(cqrs, number_generator, payment_gateway)
      [
        Shipments::Configuration.new,
        Ordering::Configuration.new(number_generator),
        Pricing::Configuration.new,
        Payments::Configuration.new(payment_gateway),
        ProductCatalog::Configuration.new,
        Crm::Configuration.new,
        Inventory::Configuration.new,
        Shipping::Configuration.new
      ].each { |c| c.call(cqrs) }
    end

    def customer_repository
      @customer_repo ||= CustomerRepository.new
    end

    def product_repository
      @product_repo ||= ProductRepository.new
    end
  end
end