
var get_buckets_id = function(req, res) {
    var params = [];
    var q = 'SELECT UNIX_TIMESTAMP(record_time) DIV ? as bucket,';
    params.push(req.query.bucket);
    q += 'sum(delta_skips)  as skips,';
    q += 'sum(delta_discon) as drops,';
    q += 'sum(delta_packets) as packets, ';
    q += 'sum(delta_payload_bytes) as payload_bytes, ';
    q += 'probes.name,';
    q += 'UNIX_TIMESTAMP(record_time) * 1000 as timestamp,';
    q += 'UNIX_TIMESTAMP(min(record_time)) * 1000 as time_min,';
    q += 'UNIX_TIMESTAMP(max(record_time)) * 1000 as time_max,';
    q += 'TIMESTAMPDIFF(SECOND, min(record_time), max(record_time)) * 1000 as period,';
    q += 'count(record_time) as records ';
    q += 'FROM log_event, probes ';
    q += 'WHERE probes.id = probe_id ';
    q += 'AND probes.id = ? ';
    params.push(req.params.probe_id);
    q += 'AND UNIX_TIMESTAMP(record_time) * 1000 BETWEEN ? AND ? ';
    params.push(req.query.time_from, req.query.time_to);
    //q += 'AND multicast_dst NOT IN ($str_elems) ';
    q += 'GROUP BY bucket ';
    q += 'ORDER BY timestamp';
    connection.query(q, params, function(err, result) {
        if (err) {
        	res.statusCode = 500;
        	logger.error('Error retrieving probes: '+ err);
            res.send('Error retrieving probes: '+ err);                
            return;
        }
	    res.header('Cache-Control', 'no-cache, no-store');
        res.header('Expires', '-1');
        res.header('Pragma', 'no-cache');
        res.send({buckets: result});
    });
}


var get_buckets_channel = function(req, res) {
    var params = [];
    var q = 'SELECT UNIX_TIMESTAMP(record_time) DIV ? as bucket, ';
    q += 'log_event.probe_id, ';
    params.push(req.query.bucket);
    q += 'stream_session.multicast_dst, ';
    q += 'stream_session.port_dst, ';
    q += 'sum(delta_skips) as skips, ';
    q += 'sum(delta_discon) as drops, ';
    q += 'sum(delta_packets) as packets, ';
    q += 'sum(delta_payload_bytes) as payload_bytes, ';
    q += 'UNIX_TIMESTAMP(record_time) * 1000 as timestamp, ';
    q += 'UNIX_TIMESTAMP(min(record_time)) * 1000 as time_min, ';
    q += 'UNIX_TIMESTAMP(max(record_time)) * 1000 as time_max, ';
    q += 'TIMESTAMPDIFF(SECOND, min(record_time), max(record_time)) * 1000 as period, ';
    q += 'count(log_event.multicast_dst) as records ';
    q += 'FROM log_event, stream_session ';
    q += 'WHERE stream_session_id = stream_session.id ';  
    q += 'AND stream_session.multicast_dst = ? ';
    q += 'AND stream_session.port_dst = ? ';
    params.push(req.params.channel, req.params.port);
    if (req.query.probe_id) {
        q += 'AND log_event.probe_id = ? ';
        params.push(req.query.probe_id);
    }
    q += 'AND UNIX_TIMESTAMP(record_time) * 1000 BETWEEN ? AND ? ';
    params.push(req.query.time_from, req.query.time_to);
    q += 'GROUP BY bucket ';
    q += 'ORDER BY log_event.probe_id, timestamp ';
    connection.query(q, params, function(err, result) {
        if (err) {
        	res.statusCode = 500;
            logger.error('Error retrieving buckets: '+ err);
            res.send('Error retrieving buckets: '+ err);
            return;
        }
	    res.header('Cache-Control', 'no-cache, no-store');
        res.header('Expires', '-1');
        res.header('Pragma', 'no-cache');
        res.send({buckets: result});
    });
}


exports.init = function(app, url) {
    app.get(url + '/id/:probe_id', function(req, res) { get_buckets_id(req, res); });
    app.get(url + '/channel/:channel/:port', function(req, res) { get_buckets_channel(req, res); });
}