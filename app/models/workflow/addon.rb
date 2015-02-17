module Workflow::Addon
  module Approver
    extend ActiveSupport::Concern
    extend SS::Addon

    set_order 50

    attr_accessor :workflow_reset

    WORKFLOW_STATE_REQUEST = "request".freeze
    WORKFLOW_STATE_APPROVE = "approve".freeze
    WORKFLOW_STATE_PENDING = "pending".freeze
    WORKFLOW_STATE_REMAND = "remand".freeze

    included do
      field :workflow_user_id, type: Integer
      field :workflow_state, type: String
      field :workflow_comment, type: String
      field :workflow_approvers, type: Workflow::Extensions::WorkflowApprovers
      field :workflow_required_counts, type: Workflow::Extensions::Route::RequiredCounts

      permit_params :workflow_user_id, :workflow_state, :workflow_comment
      permit_params workflow_approvers: []
      permit_params workflow_required_counts: []
      permit_params :workflow_reset

      before_validation :reset, if: -> { workflow_reset }
      validate :validate_workflow_approvers_presence, if: -> { workflow_state == WORKFLOW_STATE_REQUEST }
      validate :validate_workflow_approvers_level_consecutiveness, if: -> { workflow_state == WORKFLOW_STATE_REQUEST }
      validate :validate_workflow_approvers_role, if: -> { workflow_state == WORKFLOW_STATE_REQUEST }
      validate :validate_workflow_required_counts, if: -> { workflow_state == WORKFLOW_STATE_REQUEST }
    end

    public
      def status
        if state == "public" || state == "ready"
          state
        elsif workflow_state.present?
          workflow_state
        else
          state
        end
      end

      def workflow_levels
        workflow_approvers.map { |h| h[:level] }.uniq.compact.sort
      end

      def workflow_current_level
        workflow_levels.each do |level|
          required_counts = workflow_required_counts_at(level)
          approvers = workflow_approvers_at(level)
          case required_counts
          when false
            remains = approvers.select do |approver|
              approver[:state] == WORKFLOW_STATE_REQUEST || approver[:state] == WORKFLOW_STATE_PENDING
            end
            return level if remains.length > 0
          else
            approved = approvers.select { |approver| approver[:state] == WORKFLOW_STATE_APPROVE }.length
            return level if approved < required_counts
          end
        end
        nil
      end

      def workflow_approvers_at(level)
        return [] if level.nil?
        self.workflow_approvers.select do |workflow_approver|
          workflow_approver[:level] == level
        end
      end

      def workflow_required_counts_at(level)
        self.workflow_required_counts[level - 1] || false
      end

      def set_workflow_approver_state_to_request(level = workflow_current_level)
        return false if level.nil?

        copy = workflow_approvers.to_a
        targets = copy.select do |workflow_approver|
          workflow_approver[:level] == level && workflow_approver[:state] == WORKFLOW_STATE_PENDING
        end
        targets.each do |workflow_approver|
          workflow_approver[:state] = WORKFLOW_STATE_REQUEST
        end

        # Be careful, partial update is meaningless. We must update entirely.
        self.workflow_approvers = Workflow::Extensions::WorkflowApprovers.new(copy)
        true
      end

      def update_current_workflow_approver_state(user, state, comment)
        level = workflow_current_level
        return false if level.nil?

        user = user._id if user.respond_to?(:_id)
        copy = workflow_approvers.to_a
        targets = copy.select do |workflow_approver|
          workflow_approver[:level] == level && workflow_approver[:user_id] == user
        end
        # do loop even though targets length is always 1
        targets.each do |workflow_approver|
          workflow_approver[:state] = state
          workflow_approver[:comment] = comment.gsub(/\n|\r\n/, " ")
        end

        # Be careful, partial update is meaningless. We must update entirely.
        self.workflow_approvers = Workflow::Extensions::WorkflowApprovers.new(copy)
        true
      end

      def finish_workflow?
        workflow_current_level.nil?
      end

      def apply_workflow?(route)
        users = route.approvers.map do |approver|
          Cms::User.find(approver[:user_id])
        end
        unreable_users = users.reject do |user|
          allowed?(:read, user, site: cur_site)
        end
        unreable_users.each do |user|
          errors.add :base, :route_approver_unable_to_read, route: route.name, level: approver[:level], user: user.name
        end

        unapprovable_users = users.reject do |user|
          allowed?(:approve, user, site: cur_site)
        end
        unapprovable_users.each do |user|
          errors.add :base, :route_approver_unable_to_approve, route: route.name, level: approver[:level], user: user.name
        end
        errors.size == 0
      end

    private
      def reset
        if workflow_reset
          self.unset(:workflow_user_id)
          self.unset(:workflow_state)
          self.unset(:workflow_comment)
          self.unset(:workflow_approvers)
        end
      end

      def validate_workflow_approvers_presence
        errors.add :workflow_approvers, :not_select if workflow_approvers.blank?

        # check whether approver's required field is given.
        workflow_approvers.each do |workflow_approver|
          errors.add :workflow_approvers, :level_blank if workflow_approver[:level].blank?
          errors.add :workflow_approvers, :user_id_blank if workflow_approver[:user_id].blank?
          errors.add :workflow_approvers, :state_blank if workflow_approver[:state].blank?
        end
      end

      def validate_workflow_approvers_level_consecutiveness
        # level must start from 1 and level must be consecutive.
        check = 1
        workflow_levels.each do |level|
          errors.add :base, :approvers_level_missing, level: check unless level == check
          check = level + 1
        end
      end

      def validate_workflow_approvers_role
        return if errors.size > 0

        # check whether approvers have read permission.
        workflow_approvers.each do |workflow_approver|
          user = Cms::User.find(workflow_approver[:user_id])
          errors.add :workflow_approvers, :not_read, name: user.name unless allowed?(:read, user, site: cur_site)
          errors.add :workflow_approvers, :not_approve, name: user.name unless allowed?(:approve, user, site: cur_site)
        end
      end

      def validate_workflow_required_counts
        errors.add :workflow_required_counts, :not_select if workflow_required_counts.blank?

        workflow_levels.each do |level|
          required_count = workflow_required_counts_at(level)
          next if required_count == false

          approvers = workflow_approvers_at(level)
          errors.add :base, :required_count_greater_than_approvers, level: level, required_count: required_count \
            if approvers.length < required_count
        end
      end
  end
end
