CREATE TABLE customer_inventory (
  inventory_id SERIAL PRIMARY KEY,
  cust_id int NOT NULL REFERENCES customers,
  filename VARCHAR(100) NOT NULL,
  part_code INT,
  description VARCHAR(200),
  delivery_date TIMESTAMP,
  order_reference VARCHAR(50)
);