#!/usr/bin/env qore
# -*- mode: qore -*-

##                                ##
## Imports CSV file into database ##
##         Ondrej Sejvl           ##
##      27th September 2017       ##
##                                ##

%new-style
%require-types
%enable-all-warnings
%new-style
%strict-args

%requires qore >= 0.8.12

%requires pgsql
%requires TableMapper
%requires SqlUtil
%requires CsvUtil

/**
 * Simple logger to stdout
 */
class Logger {
    public {
        const DEBUG = 0;
        const INFO = 1;
        const WARN = 2;
        const ERROR = 3;
    }

    constructor (int severity) {
        self.severity = severity;
    }

    public nothing debug(string fmt, any args) {
        self.log(DEBUG, fmt, args);
    }

    public nothing info(string fmt, any args) {
        self.log(INFO, fmt, args);
    }

    public nothing warn(string fmt, any args) {
        self.log(WARN, fmt, args);
    }

    public nothing error(string fmt, any args) {
        self.log(ERROR, fmt, args);
    }

    private nothing log(int severity, string fmt, any args) {
        if (severity >= self.severity) {
            print("[", format_date("YYYY-MM-DD HH:mm:SS.ms", now_ms()), "][",
                severityText{severity}, "]: ",
                vsprintf(fmt, args), "\n");
        }
    }

    private {
        int severity;

        const severityText = (
            DEBUG: "DEBUG",
            INFO: "INFO",
            WARN: "WARN",
            ERROR: "ERROR",
        );
    }
}

/**
 * Settings constats used in this script
 */
namespace Settings {

    /**
     * Logger severity
     */
    const LOGGER_SEVERITY = Logger::DEBUG;

    /**
     * Input file path and format
     */
    namespace CSV {
        const DATA_FILE_NAME = "example-products.csv";
        const DATA_FILE_PATH = "../in/" + DATA_FILE_NAME;
        const SPEC = (
            "fields": (
                "IMEI": "int",
                "PartNmbr": "*int",
                "CustNmbr": "int",
                "Deldate": (
                    "type": "*date",
                    "format": "DD/MM/YYYY",
                ),
                "Shipper_CustNmbr": "int",
                "Orderref": "*string",
                "CustomerName": "string",
                "Description": "*string",
            ),
        );
        const OPTS = (
            "encoding": "UTF-8",
            "separator": ",",
            "quote": '"',
            "ignore_empty": True,
            "ignore_whitespace": False, # OPEN: unquoted strings may be trimmed
            "header_names": True,
            "header_lines": 1,
            "verify_columns": True,
            "tolwr": False,
        );
    }

    /**
     * Database credentials and mapping info
     */
    namespace DB {
        const USER = "postgres";
        const PASSWORD = "postgres";
        const DATABASE = "qore";

        const TABLE_CUSTOMERS = "customers";
        const TABLE_INVENTORY = "customers_inventory";
        const CUSTOMERS_MAPPER = (
            "cust_id" : ("sequence": "customers_cust_id_seq"),
            "cust_num": "num",
            "cust_name": "name",
        );
        const INVENTORY_MAPPER = (
            "inventory_id": ("sequence": "customer_inventory_inventory_id_seq"),
            "cust_id": True,
            "filename": True,
            "part_code": "partCode",
            "description": True,
            "delivery_date": ("name": "deliveryDate", "date_format": Settings::CSV::SPEC.fields.Deldate.format),
            "order_reference": "orderReference",
        );
    }
}


/**
 * Customer class for holding parsed data.
 */
class Customer {
    constructor(int num, string name) {
        self.id = NOTHING;
        self.num = num;
        self.name = name;
    }

    bool equals(Customer rhs) {
        return self.num == rhs.num &&
                self.name == rhs.name;
    }

    public {
        *int id;  # id will be filled once the Customer is stored in DB
        int num;
        string name;
    }
}

/**
 * Inventory class for holding parsed data.
 */
class Inventory {
    constructor(reference customer, string filename, *int partCode, *string description,
                *date deliveryDate, *string orderReference) {
        self.customer = customer;
        self.filename = filename;
        self.partCode = partCode;
        self.description = description;
        self.deliveryDate = deliveryDate;
        self.orderReference = orderReference;
    }

    public {
        reference customer;
        string filename;
        *int partCode;  # may be null
        *string description;  # may be null
        *date deliveryDate;  # may be null
        *string orderReference;  # may be null
    }
}


/**
 * Parses the csv file, validates the data and fills the collection.
 * @returns hash {
 *              "customers": {
 *                  "<cust_id>": <Customer>,
 *                  ...
 *              }
 *              "inventory": (<Inventory>, ...)
 *          }
 * @throws Exception when error occurs during parsing the CSV file
 */
hash sub parseCsv() {
    hash result = (
        "customers": {},
        "inventory": (),
    );

    g_lgr.info("Parsing csv file '%s'", Settings::CSV::DATA_FILE_PATH);
    CsvFileIterator it(Settings::CSV::DATA_FILE_PATH, Settings::CSV::SPEC, Settings::CSV::OPTS);
    while (it.next()) {
        on_error {
            g_lgr.error("Error while parsing CSV file on line %d", it.index());
        }

        hash line = it.getValue();
        # newly parsed customer
        Customer newCustomer(line.CustNmbr, line.CustomerName);
        # existing customer in result hash?
        *Customer customer = result.customers{line.CustNmbr};

        if (NOTHING == customer) {
            # new customer found, add to the result hash
            result.customers{line.CustNmbr} = newCustomer;
            customer = newCustomer;
        } else {
            # existing customer found, compare with the new one
            if (!customer.equals(newCustomer)) {
                g_lgr.warn(
                    "More customers with same ids but different data. Id: %d; Data 1: %y; Data 2: %y;",
                    (line.CustNmbr, newCustomer, customer));
            }
        }

        # newly parsed inventory
        push result.inventory, new Inventory(\customer, Settings::CSV::DATA_FILE_NAME,
            line.PartNmbr, line.Description, line.Deldate, line.Orderref);
    }

    return result;
}

/**
 * Inserts customers and inventory into database; all in one transaction. When customer is inserted
 * its ID is filled into the Customer object.
 * @param customers Customers data (hash of Customer objects)
 * @param inventory Inventory data (list of Inventory objects)
 */
nothing sub insertToDb(hash customers, list inventory) {
    g_lgr.info("Inserting to DB '%s:%s/***@%s'", (DSPGSQL, Settings::DB::USER, Settings::DB::DATABASE));
    Datasource ds(sprintf("%s:%s/%s@%s",DSPGSQL, Settings::DB::USER,
        Settings::DB::PASSWORD, Settings::DB::DATABASE));

    on_success {
        g_lgr.info("Committing the transaction");
        ds.commit();
    }
    on_error {
        g_lgr.error("Error occurs during filling the database data. Rollbacking the transaction");
        ds.rollback();
    }

    g_lgr.debug("Filling customers data");
    # customers
    Table customersTable(ds, "customers");
    InboundTableMapper customerMapper(customersTable, Settings::DB::CUSTOMERS_MAPPER);
    HashIterator custIt = customers.iterator();
    while (custIt.next()) {
        on_success customerMapper.flush();
        on_error customerMapper.discard();

        Customer cust = custIt.getValue();
        hash inserted = customerMapper.insertRow((
            "num": cust.num,
            "name": cust.name,
        ));
        cust.id = inserted.cust_id;
        g_lgr.debug("Inserted customer: %y", inserted);
    }

    g_lgr.debug("Filling inventory data");
    # inventory
    Table inventoryTable(ds, "customer_inventory");
    InboundTableMapper inventoryMapper(inventoryTable, Settings::DB::INVENTORY_MAPPER);
    ListIterator invIt = inventory.iterator();
    while (invIt.next()) {
        on_success inventoryMapper.flush();
        on_error inventoryMapper.discard();

        Inventory inv = invIt.getValue();
        hash inserted = inventoryMapper.insertRow((
            "cust_id": inv.customer.id,
            "filename": inv.filename,
            "partCode": inv.partCode,
            "description": inv.description,
            "deliveryDate": inv.deliveryDate,
            "orderReference": inv.orderReference,
        ));
        g_lgr.debug("Inserted inventory: %y", inserted);
    }
}


/**
 * Parses the input CSV file and inserts it into 2 tables.
 * @returns 0, when succeeded; >=1 in case of error.
 */
int sub main()
{
    # Global logger for the script
    our Logger g_lgr(Settings::LOGGER_SEVERITY);
    g_lgr.info("Starting the script...");

    try {
        hash indata = parseCsv();
        g_lgr.debug("CSV parsed successfully: customers amount: %d, inventory amount: %d",
            (elements indata.customers, elements indata.inventory));

        insertToDb(indata.customers, indata.inventory);
        g_lgr.debug("Successfully inserted into database");
    }
    catch (any ex) {
        g_lgr.error("Unexpected exception %s %s %s", (ex.err, ex.desc, ex.arg));
        g_lgr.debug("Exceptions details: %y", ex);
        return 1;
    }

    g_lgr.info("Script finished");
    return 0;
}

# run the main
exit(main());
