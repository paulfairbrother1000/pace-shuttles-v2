export const kpis = [
  {label:'Gross Revenue', value:'$2,842,650', delta:'+14.2%', tone:'good'},
  {label:'Total Journeys', value:'12,842', delta:'+11.8%', tone:'good'},
  {label:'Passengers', value:'24,796', delta:'+12.6%', tone:'good'},
  {label:'Total Commission', value:'$283,965', delta:'+13.7%', tone:'good'},
  {label:'Avg Commission Rate', value:'10.02%', delta:'+0.6pp', tone:'good'},
  {label:'Avg Revenue / Trip', value:'$221.47', delta:'+2.0%', tone:'good'},
  {label:'Avg Operator Rev / Trip', value:'$157.62', delta:'+2.3%', tone:'good'},
  {label:'Load Factor', value:'68.4%', delta:'+4.3pp', tone:'good'}
];

export const journeys = [
  {id:'JRN-250531-0830-001',time:'08:30',route:'Jolly Harbour → Nobu',country:'Antigua',status:'CONFIRMED',vehicle:'Barefoot 36',type:'Speed Boat',operator:'Barefoot',captain:'John Peters',seats:'6 / 8',revenue:'$1,600',commission:'$160',load:75},
  {id:'JRN-250531-0900-002',time:'09:00',route:'Dickenson Bay → Jolly Harbour',country:'Antigua',status:'CONFIRMED',vehicle:'Island Rider',type:'Speed Boat',operator:'Island Ride Solutions',captain:'Mike Joseph',seats:'5 / 8',revenue:'$1,250',commission:'$125',load:63},
  {id:'JRN-250531-0930-003',time:'09:30',route:"St. John's → Barbuda",country:'Antigua → Barbuda',status:'UNDER CONSIDERATION',vehicle:'TBD',type:'Speed Boat',operator:'—',captain:'—',seats:'3 / 6',revenue:'$1,080',commission:'$108',load:50},
  {id:'JRN-250531-1000-004',time:'10:00',route:'Jolly Harbour → Great Bird',country:'Antigua',status:'AT RISK',vehicle:'Sea Bliss',type:'Speed Boat',operator:'Sea Bliss',captain:'David Lewis',seats:'2 / 8',revenue:'$720',commission:'$72',load:25},
  {id:'JRN-250531-1100-005',time:'11:00',route:'Airport (ANU) → Jolly Harbour',country:'Antigua',status:'CONFIRMED',vehicle:'Coastal Taxi 2',type:'Taxi',operator:'Coastal Rides',captain:'Tanya Green',seats:'4 / 4',revenue:'$160',commission:'$16',load:100}
];

export const countries = [
  ['Antigua & Barbuda','1,842','$428,650','$232.66','$43,285','10.10%','72.3%'],
  ['Barbados','1,582','$368,950','$232.96','$36,912','10.00%','69.1%'],
  ['BVI','1,256','$301,245','$239.85','$29,784','9.89%','66.8%'],
  ['USA','1,365','$298,765','$219.04','$28,352','9.48%','70.5%'],
  ['Jamaica','1,204','$286,420','$238.13','$27,843','9.73%','65.7%']
];

export const operators = [
  {id:'barefoot',name:'Barefoot',country:'Antigua & Barbuda',revenue:'$412,850',trips:356,quality:84.7,commission:'10.0%',load:'72.4%',status:'ACTIVE'},
  {id:'island-ride',name:'Island Ride Solutions',country:'Antigua & Barbuda',revenue:'$368,950',trips:245,quality:82.1,commission:'9.3%',load:'70.1%',status:'ACTIVE'},
  {id:'coastal-rides',name:'Coastal Rides',country:'Antigua',revenue:'$362,310',trips:241,quality:81.2,commission:'8.7%',load:'68.8%',status:'ACTIVE'},
  {id:'caribe',name:'Caribe Shuttles',country:'St. Maarten',revenue:'$342,180',trips:198,quality:79.4,commission:'9.4%',load:'66.5%',status:'ACTIVE'}
];
