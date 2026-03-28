```txt
sequenceDiagram
  autonumber
  participant F as FastAPI
  participant DB as Database
  participant I as Insights
  participant M as Miox API
  participant A as AAP (Ansible)

  Note over F: Start Process

  F->>DB: Insert into Invocation Table
  F->>I: Register IDs (Correlation & Invocation)

  alt Header = build
    F->>+A: Invoke AAP API (build template)
    A-->>-F: Acknowledge Request
  else Header = day-2 operation
    F->>+M: Invoke Miox API (platform resolved from header)
    Note over M: Determine platform & select AAP template
    M->>+A: Invoke AAP template (platform-specific)
    A-->>-M: Acknowledge Request
    M-->>-F: Forward Acknowledgement
  end

  F->>DB: Update Invocation Table (Job ID & Response)
  F->>I: Update Insights Message

  Note over A: Processing Job...

  A->>DB: Update Invocation Table (Job Status)
  A->>I: Update Insights Message & Status
```
