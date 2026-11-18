-- ============================================================================
-- 002_ref_dictionaries.sql
-- REF 参考字典层：单位、物性字典、给药途径、剂型、辅料功能、五级筛选定义、
--                  AI 模型注册表、法规限值
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 2.1 计量单位
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.unit (
    unit_code     text PRIMARY KEY,
    unit_name_cn  text NOT NULL,
    dimension     text NOT NULL,
    to_si_factor  numeric,
    si_unit       text,
    comment       text
);
COMMENT ON TABLE ref.unit IS '计量单位字典：统一 ODS/DWD 中各来源的异构单位，换算到 SI 基准单位';

INSERT INTO ref.unit (unit_code, unit_name_cn, dimension, to_si_factor, si_unit, comment) VALUES
    ('1',        '无量纲',        'dimensionless', 1,        '1',        '计数、比例、概率、log 值'),
    ('g_mol',    '克每摩尔',      'molar_mass',    1,        'g/mol',    '分子量'),
    ('ang2',     '平方埃',        'area',          1e-20,    'm2',       'TPSA / PSA'),
    ('degC',     '摄氏度',        'temperature',   1,        'degC',     '熔点、玻璃化转变温度'),
    ('mg_mL',    '毫克每毫升',    'concentration', 1,        'mg/mL',    '溶解度'),
    ('mM',       '毫摩尔每升',    'concentration', 1e-3,     'mol/m3',   'CMC 临界胶束浓度'),
    ('um',       '微米',          'length',        1e-6,     'm',        '粒径 D50'),
    ('g_mL',     '克每毫升',      'density',       1,        'g/mL',     '松密度 / 振实密度'),
    ('pct',      '百分比',        'ratio',         1e-2,     '1',        '含水率、吸湿增重'),
    ('mpa_s',    '毫帕秒',        'viscosity',     1e-3,     'Pa·s',     '黏度'),
    ('mN_m',     '毫牛每米',      'surface_tension', 1e-3,   'N/m',      '表面张力'),
    ('ppm',      '百万分之一',    'mass_fraction', 1e-6,     '1',        '重金属、砷盐限度'),
    ('mg',       '毫克',          'mass',          1e-6,     'kg',       '日暴露量、规格限量'),
    ('nM',       '纳摩尔每升',    'concentration', 1e-9,     'mol/m3',   'IC50 / Ki / Kd'),
    ('uM',       '微摩尔每升',    'concentration', 1e-6,     'mol/m3',   'EC50 / 溶解度'),
    ('kcal_mol', '千卡每摩尔',    'energy',        4184,     'J/mol',    '对接打分、结合自由能'),
    ('nm',       '纳米',          'length',        1e-9,     'm',        'RMSD / 粒径'),
    ('ns',       '纳秒',          'time',          1e-9,     's',        'MD 模拟时长'),
    ('kda',      '千道尔顿',      'molar_mass',    1000,     'g/mol',    '高分子量辅料'),
    ('day',      '天',            'time',          86400,    's',        '稳定性试验时长'),
    ('cny_kg',   '元每千克',      'currency_rate', 1,        'CNY/kg',   '放大成本估算'),
    ('mgeq',     '毫克当量',      'amount',        1,        'meq',      '离子交换容量')
ON CONFLICT (unit_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.2 物性 / 描述符字典
--    约定：value_type ∈ (computed, measured, predicted, curated)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.property_def (
    property_code       text PRIMARY KEY,
    property_name_cn    text NOT NULL,
    property_name_en    text,
    dimension           text NOT NULL,
    default_unit        text REFERENCES ref.unit(unit_code),
    allowed_value_types text[] NOT NULL DEFAULT '{computed,measured,predicted,curated}',
    is_filter_field     boolean NOT NULL DEFAULT false,
    higher_is_better    boolean,
    description         text
);
COMMENT ON TABLE ref.property_def IS '物性/描述符字典：统一 RDKit 计算值、文献实测值与 AI 预测值的编码，供五级筛选统一取数';
COMMENT ON COLUMN ref.property_def.is_filter_field IS '是否作为五级筛选的硬阈值字段';
COMMENT ON COLUMN ref.property_def.allowed_value_types IS '允许的值来源类型，例如熔点只允许 measured/curated 而不允许 predicted';

INSERT INTO ref.property_def
    (property_code, property_name_cn, property_name_en, dimension, default_unit, allowed_value_types, is_filter_field, higher_is_better, description) VALUES
    ('MW',              '分子量',        'Molecular Weight',        'molar_mass',     'g_mol',  '{computed,measured,predicted}', false, null, '由分子式或结构计算'),
    ('LOGP',            '脂水分配系数',  'Partition Coefficient',   'dimensionless',  '1',      '{computed,measured,predicted}', true,  null, 'RDKit Crippen 或 XLogP3'),
    ('LOGD',            '分布系数',      'Distribution Coefficient','dimensionless',  '1',      '{computed,measured,predicted}', true,  null, '生理 pH 下的 LogD'),
    ('TPSA',            '极性表面积',    'Topological PSA',         'area',           'ang2',   '{computed,predicted}',          true,  null, '影响渗透性与水溶性'),
    ('PSA',             '范德华表面积',  'Polar Surface Area',      'area',           'ang2',   '{computed}',                    false, null, '3D 极性表面积'),
    ('HBD',             '氢键供体数',    'H-Bond Donors',           'dimensionless',  '1',      '{computed}',                    true,  null, 'Lipinski 规则字段'),
    ('HBA',             '氢键受体数',    'H-Bond Acceptors',        'dimensionless',  '1',      '{computed}',                    true,  null, 'Lipinski 规则字段'),
    ('ROT_BONDS',       '可旋转键数',    'Rotatable Bonds',         'dimensionless',  '1',      '{computed}',                    true,  null, '柔性指标'),
    ('RING_COUNT',      '环数',          'Ring Count',              'dimensionless',  '1',      '{computed}',                    false, null, '含芳香环与脂肪环'),
    ('HEAVY_ATOMS',     '重原子数',      'Heavy Atom Count',        'dimensionless',  '1',      '{computed}',                    false, null, null),
    ('MELTING_POINT',   '熔点',          'Melting Point',           'temperature',    'degC',   '{measured,curated,predicted}',   true,  null, '辅料热加工窗口的关键指标'),
    ('TGA_ONSET',       '热分解起始温度','TGA Onset Temperature',   'temperature',    'degC',   '{measured}',                    true,  true, '决定热熔挤出/喷雾干燥的工艺上限'),
    ('TG_TEMP',         '玻璃化转变温度','Glass Transition Temp',   'temperature',    'degC',   '{measured,predicted}',          true,  null, '无定形固体分散体设计'),
    ('WATER_SOLUBILITY','水溶解度',      'Water Solubility',        'concentration',  'mg_mL',  '{measured,predicted}',          true,  true, '常温纯水中的平衡溶解度'),
    ('LOGS',            '对数溶解度',    'Log Solubility',          'dimensionless',  '1',      '{computed,predicted}',          true,  true, 'mol/L 对数形式'),
    ('PKA',             '酸解离常数',    'Acid Dissociation Const', 'dimensionless',  '1',      '{measured,predicted}',          false, null, 'pH 依赖性建模'),
    ('HLB',             '亲水亲油平衡值','Hydrophile-Lipophile Balance','dimensionless','1',   '{curated,measured}',            true,  null, '乳化剂/表面活性剂选型核心参数'),
    ('CMC',             '临界胶束浓度',  'Critical Micelle Conc',   'concentration',  'mM',     '{measured,predicted}',          true,  false,'增溶能力相关'),
    ('PARTICLE_SIZE_D50','中位粒径',     'Median Particle Size D50','length',         'um',     '{measured}',                    true,  null, '粉体流动性与混合均匀度'),
    ('BULK_DENSITY',    '松密度',        'Bulk Density',            'density',        'g_mL',   '{measured}',                    true,  true, '压片/胶囊填充'),
    ('TAPPED_DENSITY',  '振实密度',      'Tapped Density',          'density',        'g_mL',   '{measured}',                    true,  true, null),
    ('CARR_INDEX',      '卡尔指数',      'Carr Compressibility Index','dimensionless','1',     '{computed}',                    true,  false,'压缩性/流动性，越小越好'),
    ('HAUSNER_RATIO',   '豪斯纳比',      'Hausner Ratio',           'dimensionless',  '1',      '{computed}',                    true,  false,'流动性，越接近 1 越好'),
    ('MOISTURE_CONTENT','含水率',        'Moisture Content',        'ratio',          'pct',    '{measured}',                    true,  false,'影响稳定性与流动性'),
    ('DVS_UPTAKE',      '动态吸湿增重',  'DVS Moisture Uptake',     'ratio',          'pct',    '{measured}',                    true,  false,'95%RH 下的吸湿增重'),
    ('VISCOSITY',       '黏度',          'Viscosity',               'viscosity',      'mpa_s',  '{measured,predicted}',          true,  null, '溶液/熔体加工性'),
    ('SURFACE_TENSION', '表面张力',      'Surface Tension',         'surface_tension','mN_m',   '{measured}',                    false, null, null),
    ('RESIDUE_IGNITION','炽灼残渣',      'Residue on Ignition',     'ratio',          'pct',    '{measured}',                    true,  false,'药典纯度指标'),
    ('HEAVY_METALS',    '重金属',        'Heavy Metals',            'mass_fraction',  'ppm',    '{measured}',                    true,  false,'ICH Q3D 元素杂质关联'),
    ('ARSENIC',         '砷盐',          'Arsenic',                 'mass_fraction',  'ppm',    '{measured}',                    true,  false,'药典限度'),
    ('HERG_PROB',       'hERG 阻滞概率', 'hERG Block Probability',  'dimensionless',  '1',      '{predicted}',                   true,  false,'心脏毒性风险'),
    ('AMES_PROB',       '致突变概率',    'Ames Mutagenicity Prob',  'dimensionless',  '1',      '{predicted}',                   true,  false,'基因毒性风险'),
    ('HEPATOTOX_PROB',  '肝毒性概率',    'Hepatotoxicity Prob',     'dimensionless',  '1',      '{predicted}',                   true,  false,null),
    ('CYTOTOX_PROB',    '细胞毒性概率',  'Cytotoxicity Prob',       'dimensionless',  '1',      '{predicted,measured}',          true,  false,'细胞活力 IC50 转换'),
    ('IRRITATION_PROB', '刺激性概率',    'Irritation Prob',         'dimensionless',  '1',      '{predicted}',                   true,  false,'注射/黏膜给药关注'),
    ('BIOAVAIL_PROB',   '口服吸收概率',  'Oral Bioavailability Prob','dimensionless','1',      '{predicted}',                   true,  true, null),
    ('HLM_STABILITY',   '肝微粒体稳定性','HLM Stability T1/2',      'time',           'day',    '{measured,predicted}',          true,  true, null),
    ('PPB',             '血浆蛋白结合率','Plasma Protein Binding',  'ratio',          'pct',    '{measured,predicted}',          false, null, null),
    ('MAX_DAILY_EXPOSURE','最大日暴露量','Max Daily Exposure',      'mass',           'mg',     '{curated}',                     true,  false,'来自 FDA IIG / 药典限值，用于安全边际计算'),
    ('IC50',            '半数抑制浓度',  'IC50',                    'concentration',  'nM',     '{measured,predicted}',          true,  false,'活性事实，规模较大时单独存 fact_activity'),
    ('BINDING_AFFINITY','结合自由能',    'Binding Free Energy',     'energy',         'kcal_mol','{predicted}',                  true,  true, '对接或 MM/PBSA 结果'),
    ('RMSD',            '均方根偏差',    'RMSD',                    'length',         'nm',     '{predicted}',                   true,  false,'MD 轨迹稳定性判据'),
    ('SYNTHESIS_STEPS', '合成步数',      'Synthesis Steps',         'dimensionless',  '1',      '{curated}',                     true,  false,'放大可行性'),
    ('COST_PER_KG',     '单位成本',      'Cost per kg',             'currency_rate',  'cny_kg', '{curated}',                     true,  false,'放大成本估算'),
    ('LEAD_TIME',       '采购交期',      'Lead Time',               'time',           'day',    '{curated}',                     true,  false,'供应链风险'),
    ('PURITY',          '纯度',          'Purity',                  'ratio',          'pct',    '{measured}',                    true,  true, 'COA 实测纯度')
ON CONFLICT (property_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.3 给药途径 / 剂型（法规限值按途径-剂型分级）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.route_admin (
    route_code     text PRIMARY KEY,
    route_name_cn  text NOT NULL,
    route_name_en  text,
    is_parental    boolean NOT NULL DEFAULT false,
    is_oral        boolean NOT NULL DEFAULT false,
    comment        text
);
COMMENT ON TABLE ref.route_admin IS '给药途径字典：辅料安全限值强依赖途径（注射 vs 口服差两个数量级）';

INSERT INTO ref.route_admin (route_code, route_name_cn, route_name_en, is_parental, is_oral, comment) VALUES
    ('ORAL',        '口服',        'Oral',                false, true,  null),
    ('IV',          '静脉注射',    'Intravenous',         true,  false, '安全性要求最高'),
    ('IM',          '肌肉注射',    'Intramuscular',       true,  false, null),
    ('SC',          '皮下注射',    'Subcutaneous',        true,  false, null),
    ('TOPICAL',     '皮肤外用',    'Topical',             false, false, null),
    ('OPHTHALMIC',  '眼用',        'Ophthalmic',          false, false, null),
    ('INHALATION',  '吸入',        'Inhalation',          false, false, null),
    ('NASAL',       '鼻用',        'Nasal',               false, false, null),
    ('RECTAL',      '直肠',        'Rectal',              false, false, null),
    ('VAGINAL',     '阴道',        'Vaginal',             false, false, null),
    ('TRANSDERMAL', '透皮',        'Transdermal',         false, false, null)
ON CONFLICT (route_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS ref.dosage_form (
    form_code     text PRIMARY KEY,
    form_name_cn  text NOT NULL,
    form_name_en  text,
    route_code    text REFERENCES ref.route_admin(route_code),
    is_sterile    boolean NOT NULL DEFAULT false
);
COMMENT ON TABLE ref.dosage_form IS '剂型字典：与给药途径组合定位法规限值行';

INSERT INTO ref.dosage_form (form_code, form_name_cn, form_name_en, route_code, is_sterile) VALUES
    ('TABLET',        '片剂',        'Tablet',                 'ORAL',       false),
    ('CAPSULE',       '胶囊剂',      'Capsule',                'ORAL',       false),
    ('GRANULE',       '颗粒剂',      'Granule',                'ORAL',       false),
    ('SUSPENSION_OR', '口服混悬剂',  'Oral Suspension',        'ORAL',       false),
    ('SOLUTION_OR',   '口服溶液剂',  'Oral Solution',          'ORAL',       false),
    ('POWDER_INJ',    '注射用粉针',  'Powder for Injection',   'IV',         true),
    ('SOLUTION_INJ',  '注射液',      'Injection Solution',     'IV',         true),
    ('SUSPENSION_INJ','注射用混悬液','Injectable Suspension',  'IM',         true),
    ('CREAM',         '乳膏剂',      'Cream',                  'TOPICAL',    false),
    ('GEL',           '凝胶剂',      'Gel',                    'TOPICAL',    false),
    ('OINTMENT',      '软膏剂',      'Ointment',               'TOPICAL',    false),
    ('EYEDROP',       '滴眼液',      'Eye Drops',              'OPHTHALMIC', true),
    ('AEROSOL',       '气雾剂',      'Aerosol',                'INHALATION', false),
    ('SUPPOSITORY',   '栓剂',        'Suppository',            'RECTAL',     false),
    ('PATCH',         '贴剂',        'Patch',                  'TRANSDERMAL',false)
ON CONFLICT (form_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.4 辅料功能分类（二级理化功能中筛的目标规格）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.excipient_function (
    function_code        text PRIMARY KEY,
    function_name_cn     text NOT NULL,
    function_name_en     text,
    parent_code          text REFERENCES ref.excipient_function(function_code),
    default_specs        jsonb NOT NULL DEFAULT '{}'::jsonb,
    key_properties       text[] NOT NULL DEFAULT '{}',
    description          text
);
COMMENT ON TABLE ref.excipient_function IS '辅料功能分类：二级"理化功能中筛"按功能反查目标物性窗口';
COMMENT ON COLUMN ref.excipient_function.default_specs IS '该功能的默认物性窗口，形如 {"HLB":[3,6],"MOISTURE_CONTENT":[0,5]}，单位见 ref.property_def';
COMMENT ON COLUMN ref.excipient_function.key_properties IS '该功能的关键物性编码，用于子集排序与解释';

INSERT INTO ref.excipient_function (function_code, function_name_cn, function_name_en, parent_code, default_specs, key_properties, description) VALUES
    ('FILLER',        '填充剂/稀释剂', 'Filler / Diluent',       null, '{"MW":[80,1200],"LOGP":[-6,1.5],"TPSA":[40,320],"HBD":[0,10]}', '{MW,LOGP,TPSA,HBD,PARTICLE_SIZE_D50,BULK_DENSITY,CARR_INDEX}', '片剂/胶囊的主体赋形；粉体物性规格待实测数据齐备后追加'),
    ('BINDER',        '黏合剂',       'Binder',                 null, '{"MW":[1000,2000000],"LOGP":[-6,2],"VISCOSITY":[5,5000]}', '{MW,VISCOSITY,TG_TEMP,MOISTURE_CONTENT}', '湿法制粒与干法辊压；高分子量是主要区分特征'),
    ('DISINTEGRANT',  '崩解剂',       'Disintegrant',           null, '{"MW":[1000,3000000],"LOGP":[-8,0],"HBD":[2,12]}', '{MW,HBD,DVS_UPTAKE,PARTICLE_SIZE_D50}', '溶出限速步骤；多为不溶性高分子'),
    ('LUBRICANT',     '润滑剂',       'Lubricant',              null, '{"MW":[200,700],"LOGP":[3,14],"TPSA":[10,80],"MELTING_POINT":[50,90]}', '{MELTING_POINT,LOGP,WATER_SOLUBILITY,PARTICLE_SIZE_D50}', '硬脂酸盐类，过量影响溶出'),
    ('GLIDANT',       '助流剂',       'Glidant',                null, '{"PARTICLE_SIZE_D50":[0.005,0.05]}',                    '{PARTICLE_SIZE_D50,BULK_DENSITY}', '改善粉体流动'),
    ('COATING',       '包衣材料',     'Coating Polymer',        null, '{"TG_TEMP":[40,160],"VISCOSITY":[5,500]}',              '{TG_TEMP,VISCOSITY,MW}', '薄膜包衣、肠溶、缓控释'),
    ('SOLUBILIZER',   '增溶剂/表面活性剂','Solubilizer / Surfactant', null, '{"LOGP":[-2,8],"TPSA":[20,220],"MW":[80,1500],"HLB":[10,18]}', '{HLB,CMC,LOGP,TPSA,WATER_SOLUBILITY}', '难溶 API 增溶'),
    ('EMULSIFIER',    '乳化剂',       'Emulsifier',             'SOLUBILIZER', '{"HLB":[8,16]}',                                 '{HLB,CMC,SURFACE_TENSION}', '乳剂与自乳化系统'),
    ('PRESERVATIVE',  '抑菌剂',       'Preservative',           null, '{"MW":[90,400],"LOGP":[-1,5],"TPSA":[20,120]}', '{MW,LOGP,WATER_SOLUBILITY,IRRITATION_PROB}', '多剂量制剂必须评估刺激性'),
    ('ANTIOXIDANT',   '抗氧剂',       'Antioxidant',            null, '{"MW":[100,700],"LOGP":[0,8],"TPSA":[20,140]}', '{LOGP,MELTING_POINT,WATER_SOLUBILITY}', '防止 API 氧化降解'),
    ('BUFFER',        '缓冲剂',       'Buffer Agent',           null, '{"MW":[60,500],"LOGP":[-3,1],"TPSA":[40,200],"PKA":[3,10]}', '{PKA,MW,WATER_SOLUBILITY}', '注射液 pH 稳定'),
    ('TONICITY',      '等渗调节剂',   'Tonicity Agent',         null, '{"WATER_SOLUBILITY":[10,1000]}',                        '{WATER_SOLUBILITY,MW}', '注射剂渗透压'),
    ('SUSPENDING',    '助悬剂',       'Suspending Agent',       null, '{"VISCOSITY":[10,2000]}',                               '{VISCOSITY,TG_TEMP}', '混悬型制剂'),
    ('HUMECTANT',     '保湿剂',       'Humectant',              null, '{"DVS_UPTAKE":[1,50]}',                                 '{DVS_UPTAKE,VISCOSITY}', null),
    ('PLASTICIZER',   '增塑剂',       'Plasticizer',            null, '{"LOGP":[-1,4]}',                                       '{LOGP,TG_TEMP}', '包衣与热熔挤出'),
    ('CRYOPROTECTANT','冻干保护剂',   'Cryoprotectant',         null, '{"TG_TEMP":[-60,20]}',                                  '{TG_TEMP,WATER_SOLUBILITY}', '冻干制剂'),
    ('RELEASE_MODIFIER','缓控释骨架材料','Release Modifier',   null, '{"VISCOSITY":[50,100000]}',                             '{VISCOSITY,MW,TG_TEMP}', '亲水凝胶骨架'),
    ('ENTERIC',       '肠溶材料',     'Enteric Polymer',        'COATING', '{"PKA":[4,6]}',                                   '{PKA,TG_TEMP}', '胃酸环境不溶'),
    ('TASTE_MASK',    '掩味剂',       'Taste Masking Agent',    null, '{"HLB":[8,20]}',                                       '{HLB,LOGP}', '儿童药与口腔崩解片')
ON CONFLICT (function_code) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.5 五级筛选阶段定义（与 ADMET / 工艺流水线一一对应）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.stage_def (
    stage_no        smallint PRIMARY KEY CHECK (stage_no BETWEEN 1 AND 5),
    stage_code      text NOT NULL UNIQUE,
    stage_name_cn   text NOT NULL,
    objective       text,
    decision_basis  text,
    entry_criteria  jsonb NOT NULL DEFAULT '{}'::jsonb,
    exit_criteria   jsonb NOT NULL DEFAULT '{}'::jsonb,
    owner_role      text,
    default_target_rows bigint
);
COMMENT ON TABLE ref.stage_def IS '五级筛选流水线定义：每级的进入条件、淘汰依据、目标留存规模';

INSERT INTO ref.stage_def (stage_no, stage_code, stage_name_cn, objective, decision_basis, entry_criteria, exit_criteria, owner_role, default_target_rows) VALUES
    (1, 'AI_VIRTUAL',   'AI 虚拟初筛',
        '用分子 AI 模型对全量候选做零成本预判，把亿级候选压到万级',
        '预测物性/毒性/可合成性 + 类药性规则硬阈值',
        '{"min_property_coverage": 0.6}',
        '{"max_retention_rate": 0.05, "require_model_version": true}',
        '数据/算法工程师', 50000),
    (2, 'PHYSCHEM',     '理化功能中筛',
        '按目标辅料功能反查物性窗口，评估是否具备功能可实现性',
        '实测+计算物性 vs 功能规格窗口的匹配度',
        '{"required_properties": ["HLB","MELTING_POINT","WATER_SOLUBILITY"]}',
        '{"min_spec_match_rate": 0.7}',
        '制剂研发工程师', 5000),
    (3, 'SAFETY_COMPAT', '生物安全与配伍深筛',
        '评估 ADMET 风险、法规限值与 API-辅料配伍稳定性',
        '法规限值安全边际 + 配伍实验/预测结果',
        '{"require_regulatory_lookup": true}',
        '{"min_safety_margin": 1.5, "max_cytotox_prob": 0.3}',
        '安全评价/分析工程师', 500),
    (4, 'MODELING',     '建模分析',
        '分子模拟验证结合模式、聚集行为与晶型干扰',
        '对接打分、MD 稳定性、自由能计算',
        '{"require_3d_structure": true}',
        '{"max_rmsd_nm": 0.3}',
        '计算化学工程师', 50),
    (5, 'SCALEUP',      '生产放大评估',
        '评估供应、成本、工艺兼容性与 GMP/药典合规性',
        '成本、交期、放大风险与法规合规',
        '{"require_supplier_quote": true}',
        '{"max_cost_per_kg": 3000}',
        '工艺/采购工程师', 10)
ON CONFLICT (stage_no) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.6 AI 模型注册表（算法对接：每个预测必须能回溯到具体版本）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.model_registry (
    model_code     text NOT NULL,
    model_version  text NOT NULL,
    task_type      text NOT NULL,
    model_name_cn  text,
    framework      text,
    artifact_uri   text,
    input_schema   jsonb NOT NULL DEFAULT '{}'::jsonb,
    output_schema  jsonb NOT NULL DEFAULT '{}'::jsonb,
    metrics        jsonb NOT NULL DEFAULT '{}'::jsonb,
    trained_at     timestamptz,
    deployed_at    timestamptz,
    status         text NOT NULL DEFAULT 'active'
                   CHECK (status IN ('active', 'shadow', 'deprecated', 'retired')),
    owner          text,
    notes          text,
    PRIMARY KEY (model_code, model_version)
);
COMMENT ON TABLE ref.model_registry IS 'AI 模型注册表：平台调用的每个模型都必须在此登记版本，预测结果回写 model_code+model_version 形成可复现链路';

INSERT INTO ref.model_registry (model_code, model_version, task_type, model_name_cn, framework, input_schema, output_schema, metrics, status, owner, notes) VALUES
    ('RDKIT_DESC', '2026.09.2', 'descriptor', 'RDKit 物性计算', 'RDKit',
        '{"smiles":"string"}', '{"MW":"num","LOGP":"num","TPSA":"num","HBD":"int","HBA":"int"}',
        '{"coverage":1.0}', 'active', '数据组', '确定性计算，作为物性基线'),
    ('PROP_MLP', 'v1.3.0', 'property_prediction', '物性预测 GNN', 'PyTorch Geometric',
        '{"smiles":"string"}', '{"MELTING_POINT":{"value":"num","ci":"num"}}',
        '{"mae_melting_point": 21.4, "r2": 0.78}', 'active', '算法组', '熔点/LogD/Tg 多任务头'),
    ('TOX_ADMET', 'v3.1.2', 'toxicity', 'ADMET 风险预测', 'Chemprop',
        '{"smiles":"string"}', '{"herg_prob":"num","ames_prob":"num","hepatotox_prob":"num"}',
        '{"auroc_herg": 0.87, "auroc_ames": 0.83}', 'active', '算法组', '输出为概率，需在 stage3 转安全边际'),
    ('DOCK_VINA', '1.2.2', 'docking', 'AutoDock Vina 对接', 'AutoDock Vina',
        '{"receptor_pdb":"path","ligand_sdf":"path"}', '{"binding_affinity":"kcal/mol","pose_rmsd":"A"}',
        '{"redock_rmsd_mean": 1.8}', 'active', '计算组', '仅对 stage3 通过者运行'),
    ('MD_GROMACS', '2024.3', 'md', '分子动力学稳定性', 'GROMACS',
        '{"complex_top":"path","duration_ns":"num"}', '{"rmsd":"nm","rmsf":"nm","hbond_count":"int"}',
        '{}', 'active', '计算组', '100ns 生产模拟'),
    ('SCALE_HEUR', 'v0.9.0', 'scaleup', '放大风险启发式评分', 'rules+GBM',
        '{"compound_sk":"int","route":"string"}', '{"cost_per_kg":"num","risk_score":"num"}',
        '{"spearman": 0.61}', 'shadow', '工艺组', '数据量不足，先影子运行')
ON CONFLICT (model_code, model_version) DO NOTHING;

-- ---------------------------------------------------------------------------
-- 2.7 法规限值（FDA IIG / 药典 / ICH Q3D）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ref.regulatory_limit (
    limit_id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    authority               text NOT NULL,
    substance_name          text NOT NULL,
    unii                    text,
    cas_number              text,
    route_code              text REFERENCES ref.route_admin(route_code),
    dosage_form_code        text REFERENCES ref.dosage_form(form_code),
    max_potency_per_unit    numeric,
    potency_unit            text REFERENCES ref.unit(unit_code),
    max_daily_exposure      numeric,
    exposure_unit           text REFERENCES ref.unit(unit_code),
    source_doc              text,
    source_version          text,
    effective_date          date,
    batch_id                uuid,
    notes                   text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT uq_reg_limit UNIQUE NULLS NOT DISTINCT
        (authority, substance_name, route_code, dosage_form_code, source_version)
);
COMMENT ON TABLE ref.regulatory_limit IS '法规限值表：FDA IIG 最大用量、药典限度等，三级"生物安全深筛"计算安全边际的分母';
COMMENT ON COLUMN ref.regulatory_limit.max_daily_exposure IS '最大日暴露量（质量单位）；安全边际 = 限值 / 实际日用量';

INSERT INTO ref.regulatory_limit
    (authority, substance_name, route_code, dosage_form_code, max_daily_exposure, exposure_unit, source_doc, source_version, notes) VALUES
    ('FDA', '示例：某注射用增溶剂', 'IV', 'SOLUTION_INJ', 100, 'mg', 'FDA IIG', 'EXAMPLE', '示例行，请以 ODS 批次 ods.fda_iig_limit 导入的真实数据替换'),
    ('FDA', '示例：某口服填充剂',   'ORAL', 'TABLET',     2000, 'mg', 'FDA IIG', 'EXAMPLE', '示例行，请以 ODS 批次导入的真实数据替换')
ON CONFLICT DO NOTHING;

COMMIT;
