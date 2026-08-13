module Reports
  class CustomerReport
    def self.call(region, limit: 10)
      [region, limit]
    end
  end
end
