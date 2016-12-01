# Localize authorization request alert in your Localizable.strings
# "Tgios::BeaconManager.request_alert.title.denied" = "Location services are off";
# "Tgios::BeaconManager.request_alert.title.disabled" = "Background location is not enabled";
# "Tgios::BeaconManager.request_alert.message" = "To use background location you must turn on 'Always' in the Location Services Settings";

module Tgios
  class FakeBeacon
    attr_accessor :proximityUUID, :major, :minor, :accuracy, :proximity, :rssi

    def initialize(attributes)
      attributes.each do |k, v|
        k = :proximityUUID if k.to_s == 'uuid'
        instance_variable_set("@#{k}", v)
      end
      @proximityUUID ||= NSUUID.new
      @major ||= 34702
      @minor ||= 31202
      @accuracy ||= 3.0
      @rssi ||= -85
      @proximity ||= CLProximityFar
    end
  end

  class BeaconManager < BindingBase
    attr_accessor :range_method, :range_limit, :tolerance, :current_beacon, :background
    ALGORITHMS = [:continue, :timeout]

    BeaconFoundKey = 'Tgios::BeaconManager::BeaconFound'
    BeaconsFoundKey = 'Tgios::BeaconManager::BeaconsFound'
    EnterRegionKey = 'Tgios::BeaconManager::EnterRegion'
    ExitRegionKey = 'Tgios::BeaconManager::ExitRegion'

    def self.default=(val)
      @default = val
    end

    def self.default
      @default
    end

    #############################################
    # range_method: :rssi or :accuracy
    # range_limit: around -70 for :rssi / around 1.5 (meters) for :accuracy
    # background: range beacons when device is in background
    # algorithm: :continue or :timeout
    # tolerance: for algorithm continue: number of times a beacon is ranged continuously required to trigger beacon changed event, for algorithm timeout: time in seconds for a beacon marked as changed
    #############################################

    def initialize(options)
      @events = {}
      @previous_beacons = []
      @beacons_last_seen_at = {}
      @background = options[:background]

      self.algorithm = (options[:algorithm] || :continue)
      @tolerance = (options[:tolerance] || 5)

      @range_method = (options[:range_method] || :rssi)
      @range_limit = (options[:range_limit] || -70)

      @regions = []
      region_options = options[:regions]
      if !region_options.is_a?(Array)
        region_options = [{uuid: options[:uuid], major: options[:major], minor: options[:minor]}]
      end

      region_options.each do |region_hash|
        if region_hash.is_a?(Hash)
          uuid = region_hash[:uuid]
          major = region_hash[:major]
          minor = region_hash[:minor]
        else
          uuid = region_hash
        end
        uuid = uuid.upcase
        nsuuid = NSUUID.alloc.initWithUUIDString(uuid)
        region = if major && minor
                   CLBeaconRegion.alloc.initWithProximityUUID(nsuuid, major: major, minor: minor, identifier: identifier(uuid, major, minor))
                 elsif major
                   CLBeaconRegion.alloc.initWithProximityUUID(nsuuid, major: major, identifier: identifier(uuid, major, minor))
                 else
                   CLBeaconRegion.alloc.initWithProximityUUID(nsuuid, identifier: identifier(uuid, major, minor))
                 end
        @regions << {region: region, active: false}

        region.notifyOnEntry = true
        region.notifyOnExit = true
        region.notifyEntryStateOnDisplay = true
      end

      central_manager
      start_monitor

      UIApplicationWillEnterForegroundNotification.add_observer(self, 'on_enter_foreground:')
      UIApplicationDidEnterBackgroundNotification.add_observer(self, 'on_enter_background:')

    end

    def identifier(uuid, major, minor)
      [uuid, major, minor].join('/')
    end

    def on(event_key,&block)
      @events[event_key] = block.weak!
      self
    end

    def algorithm=(val)
      alg = val.to_s.to_sym
      return unless alg.present?
      if @algorithm != alg
        @previous_beacons.clear
      end
      raise ArgumentError.new("Algorithm not found, valid algorithm are: [#{ALGORITHMS.join(', ')}]") unless ALGORITHMS.include?(alg)

      @algorithm = alg
    end

    def locationManager(manager, didDetermineState: state, forRegion: region)
      NSLog "didDetermineState #{state}"
      if state == CLRegionStateInside
        manager.startRangingBeaconsInRegion(region)
        did_enter_region(region)
      elsif state == CLRegionStateOutside
        did_exit_region(region)
      end
    end

    def locationManager(manager, didEnterRegion: region)
      did_enter_region(region)
    end

    def locationManager(manager, didExitRegion: region)
      did_exit_region(region)
    end

    def locationManager(manager, didRangeBeacons: beacons, inRegion: region)

      region_hash = get_region_hash(region)
      return unless region_hash[:active]

      beacons = beacons.sort_by{|b| b.try(@range_method)}
      beacons = beacons.reverse if @range_method == :rssi
      known_beacons = beacons.select{|b| b.proximity != CLProximityUnknown}
      unknown_beacons = beacons - known_beacons
      beacon = nil
      beacons_in_range = known_beacons.select{|b| @range_method == :accuracy ? b.try(@range_method) <= @range_limit : b.try(@range_method) >= @range_limit}
      beacon = beacons_in_range.first if beacons_in_range.present?
      
      NSLog("beacons_in_range: ")
      beacons_in_range.each_with_index do |bir, i|
        NSLog("##{i}: major: #{bir.major}, minor: #{bir.minor}, accuracy: #{bir.accuracy.round(3)}, rssi: #{bir.rssi}")
      end
      push_beacon(beacon) # nil value will signify null beacon

      if has_event(:beacons_found)
        # use known_beacons + unknown_beacons to make sure closest range comes to the top
        @events[:beacons_found].call(beacons_in_range, known_beacons + unknown_beacons, @current_beacon)
      end

      if has_event(:beacon_found)
        @events[:beacon_found].call(@current_beacon)
      end

      BeaconFoundKey.post_notification(self, {region: region, beacon: @current_beacon})
      BeaconsFoundKey.post_notification(self, {region: region, beacon: @current_beacon, beacons_in_range: beacons_in_range, any_beacons: known_beacons + unknown_beacons})
    end

    def locationManager(manager, rangingBeaconsDidFailForRegion: region, withError: error)
      @events[:ranging_failed].call(region, error) if has_event(:ranging_failed)
    end

    def location_manager
      @location_manager ||=
          begin
            manager = CLLocationManager.alloc.init
            manager.delegate = self
            request_authorization(manager)
            manager
          end
    end

    def request_authorization(manager)
      if manager.respond_to?(:requestAlwaysAuthorization)
        status = CLLocationManager.authorizationStatus
        if status == KCLAuthorizationStatusAuthorizedWhenInUse || status == KCLAuthorizationStatusDenied
          denied_title = 'Tgios::BeaconManager.request_alert.title.denied'._
          denied_title = 'Location services are off' if denied_title == 'Tgios::BeaconManager.request_alert.title.denied'

          disabled_title = 'Tgios::BeaconManager.request_alert.title.disabled'._
          disabled_title = 'Background location is not enabled' if disabled_title == 'Tgios::BeaconManager.request_alert.title.disabled'

          message = 'Tgios::BeaconManager.request_alert.message'._
          message = "To use background location you must turn on 'Always' in the Location Services Settings" if message == 'Tgios::BeaconManager.request_alert.message'

          title = (status == KCLAuthorizationStatusDenied) ? denied_title : disabled_title
          UIAlertView.alert(title, message: message)
        else
          manager.requestAlwaysAuthorization
        end
      end

    end

    def start_monitor
      @regions.each do |region_hash|
        region = region_hash[:region]
        location_manager.startMonitoringForRegion(region)
        location_manager.requestStateForRegion(region)
      end
    end

    def stop_monitor
      @regions.each do |region_hash|
        region = region_hash[:region]
        location_manager.stopRangingBeaconsInRegion(region)
        location_manager.stopMonitoringForRegion(region)
      end
    end

    def on_enter_foreground(noti)
      self.performSelector('start_monitor', withObject: nil, afterDelay:1)
    end

    def on_enter_background(noti)
      stop_monitor unless @background
    end

    def did_enter_region(region)
      if region.isKindOfClass(CLBeaconRegion)

        region_hash = get_region_hash(region)
        region_hash[:active] = true

        location_manager.startRangingBeaconsInRegion(region)
        if has_event(:enter_region)
          @events[:enter_region].call(region)
        end
        EnterRegionKey.post_notification(self, {region: region})
      end
    end

    def did_exit_region(region)
      if region.isKindOfClass(CLBeaconRegion)

        region_hash = get_region_hash(region)
        region_hash[:active] = false

        location_manager.stopRangingBeaconsInRegion(region)
        @previous_beacons.delete_if {|b| self.class.beacon_in_region(b, region)}
        if self.class.beacon_in_region(@current_beacon, region)
          @current_beacon = nil
        end
        if has_event(:exit_region)
          @events[:exit_region].call(region)
        end
        ExitRegionKey.post_notification(self, {region: region})
      end
    end

    def central_manager
      @central_manager ||= CBCentralManager.alloc.initWithDelegate(self, queue: nil)
    end

    def centralManagerDidUpdateState(central)
      @regions.each do |region_hash|
        region = region_hash[:region]
        case central.state
          when CBCentralManagerStatePoweredOff, CBCentralManagerStateUnsupported, CBCentralManagerStateUnauthorized
            did_exit_region(region)
          when CBCentralManagerStatePoweredOn
            did_enter_region(region)
          when CBCentralManagerStateResetting
          when CBCentralManagerStateUnknown
          else
        end
      end
    end

    def has_event(event)
      @events.has_key?(event)
    end

    def push_beacon(beacon)
      case @algorithm
        when :continue
          if beacon_eqs(beacon, @current_beacon)
            @current_beacon = beacon
          else
            if @previous_beacons.find { |b| !beacon_eqs(beacon, b) }.blank? # all previous beacons is the new beacon
              @current_beacon = beacon
            else
              @current_beacon = nil if @previous_beacons.find{ |b| beacon_eqs(@current_beacon, b)}.blank? # all previous beacons is not the current beacon
            end
          end
          @previous_beacons << beacon
          @previous_beacons.delete_at(0) if @previous_beacons.length > @tolerance

        when :timeout
          time_now = Time.now
          beacon_hash = {beacon: beacon, time: time_now}
          @beacons_last_seen_at[self.class.beacon_key(beacon)] = beacon_hash

          while @previous_beacons.present? && time_now - @previous_beacons.first[:time] > @tolerance do
            @previous_beacons.delete_at(0)
          end
          @previous_beacons << beacon_hash

          current_beacon_hash = @beacons_last_seen_at[self.class.beacon_key(@current_beacon)]
          if current_beacon_hash

          end
          if !current_beacon_hash || time_now - current_beacon_hash[:time] < @tolerance
             # current beacon not change
          else
            count_hash = @previous_beacons.each_with_object(Hash.new(0)) {|e, h| h[self.class.beacon_key(e[:beacon])] += @tolerance - (time_now - e[:time])} # beacon has more weighting if time is later
            max_beacon_key = count_hash.max_by(&:last).first
            @current_beacon = @beacons_last_seen_at[max_beacon_key][:beacon]
          end
        else
          @current_beacon = beacon
      end
    end

    def beacon_eqs(beacon1, beacon2)
      self.class.beacon_eqs(beacon1, beacon2)
    end

    def self.beacon_eqs(beacon1, beacon2)
      return beacon1 == beacon2 if beacon1.nil? || beacon2.nil?
      beacon1.minor == beacon2.minor && beacon1.major == beacon2.major && beacon1.proximityUUID.UUIDString.upcase == beacon2.proximityUUID.UUIDString.upcase
    end

    def self.region_eqs(region1, region2)
      return region1 == region2 if region1.nil? || region2.nil?
      region1.identifier.upcase == region2.identifier.upcase
    end

    def self.beacon_in_region(beacon, region)
      return false unless beacon

      match = beacon.proximityUUID == region.proximityUUID
      return false unless match
      major = region.major
      if major
        match = match && beacon.major == major
        return false unless match
        minor = region.minor
        if minor
          match = match && beacon.minor == minor
        end
      end
      match
    end

    def self.beacon_key(beacon)
      [beacon.try(:proximityUUID).try(:UUIDString).try(:upcase), beacon.try(:major), beacon.try(:minor)].join('/')
    end

    def new_fake_beacon(options)
      region_hash = @regions.first
      region = region_hash[:region] if region_hash
      region_options = region ? {uuid: region.proximityUUID, major: region.major, minor: region.minor} : {}
      FakeBeacon.new(region_options.merge(options))
    end

    def get_region_hash(region)
      region_hash = @regions.find{|r| self.class.region_eqs(r[:region], region) }
      region_hash || {}
    end


    def self.supported
      CLLocationManager.isRangingAvailable
    end

    def onPrepareForRelease
      UIApplicationWillEnterForegroundNotification.remove_observer(self)
      UIApplicationDidEnterBackgroundNotification.remove_observer(self)
      stop_monitor
      @location_manager = nil
      @events = nil
      @current_beacon = nil
      @previous_beacons = nil
      @regions = []
    end

    def dealloc
      onPrepareForRelease
      super
    end
  end
end
