--
-- Table structure for table 'radius_accounting_log'
--

DROP TABLE IF EXISTS radius_accounting_log;

CREATE TABLE radius_accounting_log (
  id int NOT NULL AUTO_INCREMENT,
  start_at TIMESTAMP NOT NULL,
  end_at TIMESTAMP default "0000-00-00 00:00:00",
  mac char(17) NOT NULL,
  acctsessiontime int(12) default NULL,
  acctinputoctets bigint(20) default NULL,
  acctoutputoctets bigint(20) default NULL,
  acctinputpackets bigint(20) default NULL,
  acctoutputpackets bigint(20) default NULL,
  event_type varchar(255) NULL,
  PRIMARY KEY (id),
  KEY `start_at` (start_at),
  KEY `end_at` (end_at),
  KEY `mac` (mac),
) ENGINE=InnoDB;

